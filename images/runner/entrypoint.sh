#!/usr/bin/env bash
# Agentex Agent Runner
# Runs inside the agent pod. Reads its Task CR, executes work via OpenCode, posts results.
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-unknown}"
AGENT_ROLE="${AGENT_ROLE:-worker}"
TASK_CR_NAME="${TASK_CR_NAME:-}"
NAMESPACE="${NAMESPACE:-agentex}"
REPO="${REPO:-pnz1990/agentex}"
BEDROCK_MODEL="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-5-v1:0}"
WORKSPACE="/workspace"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$AGENT_NAME] $*"; }

# ── 0. Configure kubectl ─────────────────────────────────────────────────────
log "Configuring kubectl for cluster ${CLUSTER:-agentex}..."
aws eks update-kubeconfig --name "${CLUSTER:-agentex}" --region "${BEDROCK_REGION:-us-west-2}"

# ── 1. Announce startup ──────────────────────────────────────────────────────
log "Agent starting. Role=$AGENT_ROLE Task=$TASK_CR_NAME"

post_message() {
  local to="$1" body="$2" type="${3:-status}"
  local msg_name="msg-${AGENT_NAME}-$(date +%s)"
  kubectl apply -f - <<EOF
apiVersion: agentex.io/v1alpha1
kind: Message
metadata:
  name: ${msg_name}
  namespace: ${NAMESPACE}
spec:
  from: "${AGENT_NAME}"
  to: "${to}"
  thread: "${TASK_CR_NAME}"
  messageType: "${type}"
  body: |
$(echo "$body" | sed 's/^/    /')
EOF
}

post_thought() {
  local content="$1" type="${2:-observation}" confidence="${3:-7}"
  local thought_name="thought-${AGENT_NAME}-$(date +%s)"
  kubectl apply -f - <<EOF
apiVersion: agentex.io/v1alpha1
kind: Thought
metadata:
  name: ${thought_name}
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "${TASK_CR_NAME}"
  thoughtType: "${type}"
  confidence: ${confidence}
  content: |
$(echo "$content" | sed 's/^/    /')
EOF
}

patch_task_status() {
  local phase="$1" outcome="${2:-}"
  kubectl patch task "$TASK_CR_NAME" -n "$NAMESPACE" \
    --type=merge \
    -p "{\"status\":{\"phase\":\"${phase}\",\"agentRef\":\"${AGENT_NAME}\",\"outcome\":\"${outcome}\"}}" 2>/dev/null || true
}

# ── 2. Read Task CR ──────────────────────────────────────────────────────────
log "Reading task CR..."
TASK_JSON=$(kubectl get task "$TASK_CR_NAME" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
TASK_TITLE=$(echo "$TASK_JSON" | jq -r '.spec.title // "No title"')
TASK_DESC=$(echo "$TASK_JSON" | jq -r '.spec.description // ""')
TASK_CONTEXT=$(echo "$TASK_JSON" | jq -r '.spec.context // ""')
TASK_ISSUE=$(echo "$TASK_JSON" | jq -r '.spec.githubIssue // 0')
TASK_EFFORT=$(echo "$TASK_JSON" | jq -r '.spec.effort // "M"')

log "Task: $TASK_TITLE (effort=$TASK_EFFORT issue=#$TASK_ISSUE)"
patch_task_status "InProgress"
post_message "broadcast" "Starting task: $TASK_TITLE" "status"
post_thought "Task received: $TASK_TITLE. Effort=$TASK_EFFORT. Beginning analysis." "observation" 8

# ── 3. Clone repo ────────────────────────────────────────────────────────────
log "Cloning repo..."
gh auth setup-git
mkdir -p "$WORKSPACE/repo"
git clone "https://github.com/$REPO.git" "$WORKSPACE/repo" --depth=1
cd "$WORKSPACE/repo"

# ── 4. Build OpenCode prompt ─────────────────────────────────────────────────
PROMPT=$(cat <<PROMPT
You are an AI agent named ${AGENT_NAME} with role ${AGENT_ROLE} working on the agentex project.

Your assigned task: ${TASK_TITLE}

Description: ${TASK_DESC}

Context: ${TASK_CONTEXT}

$([ "$TASK_ISSUE" != "0" ] && echo "GitHub Issue: #${TASK_ISSUE} — read it with: gh issue view ${TASK_ISSUE} --repo ${REPO}")

You are running inside a Kubernetes pod. You have access to:
- kubectl (for reading/writing CRs in namespace agentex)
- gh CLI (authenticated, repo ${REPO})
- git (cloned repo at /workspace/repo)
- aws CLI (Bedrock via IRSA — no credentials needed)

CRITICAL RULES:
1. Work in an isolated clone: mkdir -p /workspace/issue-N && git clone https://github.com/${REPO} /workspace/issue-N
2. Never push directly to main — always branch + PR
3. Before finishing: create at least one follow-up Task CR for the next agent
4. Post a completion Message CR when done
5. If you identify any self-improvement opportunity for the agentex platform itself, create a GitHub Issue for it

After completing the task, run this to mark it done:
kubectl patch task ${TASK_CR_NAME} -n ${NAMESPACE} --type=merge -p '{"status":{"phase":"Done","completedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}'
PROMPT
)

# ── 5. Run OpenCode headlessly ───────────────────────────────────────────────
log "Running OpenCode..."
post_thought "About to execute OpenCode with task prompt. Model=$BEDROCK_MODEL" "decision" 9

# Configure OpenCode to use Bedrock
mkdir -p /root/.config/opencode
cat > /root/.config/opencode/config.json <<CONFIG
{
  "model": "amazon-bedrock/${BEDROCK_MODEL}"
}
CONFIG

# Run OpenCode non-interactively with the task as input
echo "$PROMPT" | opencode run --print-logs 2>&1 | tee /tmp/opencode-output.txt
OPENCODE_EXIT=${PIPESTATUS[1]}

# ── 6. Post results ──────────────────────────────────────────────────────────
if [ $OPENCODE_EXIT -eq 0 ]; then
  log "OpenCode completed successfully"
  patch_task_status "Done" "Completed successfully"
  post_message "broadcast" "Task completed: $TASK_TITLE" "status"
  post_thought "Task finished successfully. See output log for details." "observation" 9
else
  log "OpenCode exited with code $OPENCODE_EXIT"
  patch_task_status "Done" "Completed with exit code $OPENCODE_EXIT"
  post_message "broadcast" "Task finished (exit=$OPENCODE_EXIT): $TASK_TITLE" "status"
fi

# ── 7. Check for unread messages addressed to this agent ────────────────────
log "Checking inbox..."
INBOX=$(kubectl get messages -n "$NAMESPACE" \
  -l "agentex/to=${AGENT_NAME}" \
  -o json 2>/dev/null | jq -r '.items[] | select(.spec.read==false) | .metadata.name' || true)
if [ -n "$INBOX" ]; then
  log "Unread messages: $(echo "$INBOX" | wc -l)"
  # Mark as read
  for msg in $INBOX; do
    kubectl patch message "$msg" -n "$NAMESPACE" --type=merge -p '{"spec":{"read":true}}' 2>/dev/null || true
  done
fi

log "Agent exiting cleanly."
