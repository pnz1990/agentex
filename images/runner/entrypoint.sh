#!/usr/bin/env bash
# Agentex Agent Runner v2
# Runs inside the agent pod. Reads its Task CR, processes inbox, executes work
# via OpenCode, posts results, and always seeds follow-up work before exiting.
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-unknown}"
AGENT_ROLE="${AGENT_ROLE:-worker}"
TASK_CR_NAME="${TASK_CR_NAME:-}"
SWARM_REF="${SWARM_REF:-}"
NAMESPACE="${NAMESPACE:-agentex}"
REPO="${REPO:-pnz1990/agentex}"
CLUSTER="${CLUSTER:-agentex}"
BEDROCK_REGION="${BEDROCK_REGION:-us-west-2}"
# Cross-region inference profile — works across all us-* regions
BEDROCK_MODEL="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-5-v1:0}"
WORKSPACE="/workspace"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$AGENT_NAME] $*"; }

# ── 0. Configure kubectl ──────────────────────────────────────────────────────
log "Configuring kubectl for cluster $CLUSTER ..."
aws eks update-kubeconfig --name "$CLUSTER" --region "$BEDROCK_REGION"

# ── 1. Helper functions ───────────────────────────────────────────────────────
post_message() {
  local to="$1" body="$2" type="${3:-status}"
  # Unique name: agent + epoch millis to avoid collisions
  local msg_name="msg-${AGENT_NAME}-$(date +%s%3N)"
  kubectl apply -f - <<EOF 2>/dev/null || true
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
  local thought_name="thought-${AGENT_NAME}-$(date +%s%3N)"
  kubectl apply -f - <<EOF 2>/dev/null || true
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
    -p "{\"status\":{\"phase\":\"${phase}\",\"agentRef\":\"${AGENT_NAME}\",\"outcome\":\"${outcome}\"}}" \
    2>/dev/null || true
}

create_followup_task() {
  local title="$1" desc="$2" role="${3:-worker}" effort="${4:-M}" issue="${5:-0}"
  local ts task_name
  ts=$(date +%s)
  task_name="task-followup-${ts}"
  log "Creating follow-up Task CR: $task_name"
  kubectl apply -f - <<EOF 2>/dev/null || true
apiVersion: agentex.io/v1alpha1
kind: Task
metadata:
  name: ${task_name}
  namespace: ${NAMESPACE}
spec:
  title: "${title}"
  description: "${desc}"
  role: "${role}"
  effort: "${effort}"
  githubIssue: ${issue}
  priority: 5
EOF
}

# ── 2. Announce startup ───────────────────────────────────────────────────────
log "Agent starting. Role=$AGENT_ROLE Task=$TASK_CR_NAME Model=$BEDROCK_MODEL"

# ── 3. Process inbox before running ──────────────────────────────────────────
log "Processing inbox..."
INBOX_MESSAGES=""
# Collect messages addressed to this agent OR broadcast messages not yet read
INBOX_JSON=$(kubectl get messages -n "$NAMESPACE" \
  -o json 2>/dev/null || echo '{"items":[]}')

# Messages to this agent
DIRECT_MSGS=$(echo "$INBOX_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | select(.spec.to == $name and (.spec.read == false or .spec.read == null)) |
   "FROM: \(.spec.from)\nTYPE: \(.spec.messageType)\nTHREAD: \(.spec.thread)\n\(.spec.body)\n---"' \
  2>/dev/null || true)

# Broadcast messages
BROADCAST_MSGS=$(echo "$INBOX_JSON" | jq -r \
  '.items[] | select(.spec.to == "broadcast" and (.spec.read == false or .spec.read == null)) |
   "FROM: \(.spec.from)\nTYPE: \(.spec.messageType)\nTHREAD: \(.spec.thread)\n\(.spec.body)\n---"' \
  2>/dev/null || true)

if [ -n "$DIRECT_MSGS" ] || [ -n "$BROADCAST_MSGS" ]; then
  INBOX_MESSAGES=$(printf "=== INBOX ===\n%s\n%s\n=============\n" "$DIRECT_MSGS" "$BROADCAST_MSGS")
  MSG_COUNT=$(echo "$INBOX_JSON" | jq '[.items[] | select(.spec.to == "'"$AGENT_NAME"'" or .spec.to == "broadcast") | select(.spec.read == false or .spec.read == null)] | length' 2>/dev/null || echo 0)
  log "Found $MSG_COUNT unread messages"
  post_thought "Inbox has unread messages. Will incorporate into task execution." "observation" 7
fi

# Mark all as read
for msg_name in $(echo "$INBOX_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | select(.spec.to == $name or .spec.to == "broadcast") | .metadata.name' \
  2>/dev/null || true); do
  kubectl patch message "$msg_name" -n "$NAMESPACE" \
    --type=merge -p '{"spec":{"read":true}}' 2>/dev/null || true
done

# ── 4. Read current Thoughts from peers (shared context) ─────────────────────
log "Reading peer thoughts for shared context..."
PEER_THOUGHTS=$(kubectl get thoughts -n "$NAMESPACE" \
  -o json 2>/dev/null | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[-10:] | .[] | select(.spec.agentRef != $name) |
   "[\(.spec.agentRef)/\(.spec.thoughtType)/confidence=\(.spec.confidence)]: \(.spec.content)"' \
  2>/dev/null || true)

# ── 5. Read Task CR ───────────────────────────────────────────────────────────
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

# ── 6. Clone repo ─────────────────────────────────────────────────────────────
log "Cloning repo..."
gh auth setup-git
mkdir -p "$WORKSPACE/repo"
git clone "https://github.com/$REPO.git" "$WORKSPACE/repo" --depth=1
cd "$WORKSPACE/repo"

# ── 7. Configure OpenCode ─────────────────────────────────────────────────────
mkdir -p "${HOME}/.config/opencode"
cat > "${HOME}/.config/opencode/config.json" <<CONFIG
{
  "model": "amazon-bedrock/${BEDROCK_MODEL}"
}
CONFIG

# ── 8. Build OpenCode prompt ──────────────────────────────────────────────────
ISSUE_LINE=""
if [ "$TASK_ISSUE" != "0" ]; then
  ISSUE_LINE="GitHub Issue: #${TASK_ISSUE} — read it with: gh issue view ${TASK_ISSUE} --repo ${REPO}"
fi

SWARM_LINE=""
if [ -n "$SWARM_REF" ]; then
  SWARM_LINE="You are part of Swarm: ${SWARM_REF}. Read swarm state: kubectl get configmap ${SWARM_REF}-state -n ${NAMESPACE} -o yaml"
fi

PEER_CONTEXT=""
if [ -n "$PEER_THOUGHTS" ]; then
  PEER_CONTEXT="=== RECENT PEER THOUGHTS (shared context) ===
${PEER_THOUGHTS}
============================================="
fi

PROMPT=$(cat <<PROMPT
You are an AI agent named ${AGENT_NAME} with role ${AGENT_ROLE} working on the agentex platform.

Your assigned task: ${TASK_TITLE}

Description:
${TASK_DESC}

Context:
${TASK_CONTEXT}

${ISSUE_LINE}

${SWARM_LINE}

${INBOX_MESSAGES}

${PEER_CONTEXT}

You are running inside a Kubernetes pod on the agentex EKS cluster. You have:
- kubectl (CRs in namespace agentex)
- gh CLI (authenticated, repo ${REPO})
- git (repo cloned at /workspace/repo, branch: main)
- aws CLI (Bedrock via Pod Identity — no explicit credentials needed)
- opencode CLI

CRITICAL RULES:
1. All code changes: branch off main, never push directly to main — always PR
   Branch name: issue-N-short-description  (or feature-short-description if no issue)
2. Before finishing: create at least one follow-up Task CR for the next agent
   kubectl apply -f - (with Task CR yaml)
3. Post a completion Message CR when done
4. After completing work, read manifests/rgds/ and AGENTS.md
   Identify ONE improvement to the agentex platform (S effort preferred)
   Create a GitHub Issue: gh issue create --repo ${REPO} --title "..." --body "..."
   If effort is S, implement it immediately in the same PR
5. Mark task done:
   kubectl patch task ${TASK_CR_NAME} -n ${NAMESPACE} --type=merge \\
     -p '{"status":{"phase":"Done","completedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agentRef":"${AGENT_NAME}"}}'
6. Announce completion:
   kubectl apply -f - (Message CR with type=status, to=broadcast)
PROMPT
)

# ── 9. Run OpenCode headlessly ────────────────────────────────────────────────
log "Running OpenCode..."
post_thought "Executing OpenCode. Model=$BEDROCK_MODEL. Effort=$TASK_EFFORT." "decision" 9

echo "$PROMPT" | opencode run --print-logs 2>&1 | tee /tmp/opencode-output.txt
OPENCODE_EXIT=${PIPESTATUS[1]}

# ── 10. Post results ──────────────────────────────────────────────────────────
if [ "$OPENCODE_EXIT" -eq 0 ]; then
  log "OpenCode completed successfully"
  patch_task_status "Done" "Completed successfully"
  post_message "broadcast" "Task completed: $TASK_TITLE (agent=$AGENT_NAME role=$AGENT_ROLE)" "status"
  post_thought "Task finished successfully." "observation" 9
else
  log "OpenCode exited with code $OPENCODE_EXIT"
  patch_task_status "Done" "Completed with exit code $OPENCODE_EXIT"
  post_message "broadcast" "Task finished (exit=$OPENCODE_EXIT): $TASK_TITLE" "status"
  post_thought "OpenCode exited non-zero ($OPENCODE_EXIT). Check /tmp/opencode-output.txt for details." "observation" 5
fi

# ── 11. Safety net: ensure a follow-up Task CR exists ────────────────────────
# Check if OpenCode already created follow-up tasks (look for tasks created in last 10 min)
RECENT_TASKS=$(kubectl get tasks -n "$NAMESPACE" \
  -o json 2>/dev/null | jq \
  --arg cutoff "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
  '[.items[] | select(.metadata.creationTimestamp > $cutoff)] | length' \
  2>/dev/null || echo "0")

if [ "$RECENT_TASKS" -eq 0 ]; then
  log "No follow-up tasks created by OpenCode — seeding continuity task"
  create_followup_task \
    "Continue: $TASK_TITLE" \
    "Follow-up from agent $AGENT_NAME. Review output at /tmp/opencode-output.txt stored in prior pod. Original task: $TASK_CR_NAME. Role: $AGENT_ROLE." \
    "$AGENT_ROLE" \
    "M" \
    "$TASK_ISSUE"
fi

# ── 12. Update Swarm state if member ─────────────────────────────────────────
if [ -n "$SWARM_REF" ]; then
  log "Updating swarm state for $SWARM_REF..."
  CURRENT_COMPLETED=$(kubectl get configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
    -o jsonpath='{.data.tasksCompleted}' 2>/dev/null || echo "0")
  NEW_COMPLETED=$(( CURRENT_COMPLETED + 1 ))
  kubectl patch configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
    --type=merge \
    -p "{\"data\":{\"tasksCompleted\":\"${NEW_COMPLETED}\"}}" \
    2>/dev/null || true
fi

log "Agent exiting cleanly. Task=$TASK_CR_NAME Role=$AGENT_ROLE"
