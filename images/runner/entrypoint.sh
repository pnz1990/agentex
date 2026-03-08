#!/usr/bin/env bash
# Agentex Agent Runner v3 — self-perpetuating loop
#
# The prime directive: when this agent exits, work MUST continue.
# Every agent spawns at least one successor Agent CR before dying.
# The system never idles. No human needed after initial seed.
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-unknown}"
AGENT_ROLE="${AGENT_ROLE:-worker}"
TASK_CR_NAME="${TASK_CR_NAME:-}"
SWARM_REF="${SWARM_REF:-}"
NAMESPACE="${NAMESPACE:-agentex}"
REPO="${REPO:-pnz1990/agentex}"
CLUSTER="${CLUSTER:-agentex}"
BEDROCK_REGION="${BEDROCK_REGION:-us-west-2}"
BEDROCK_MODEL="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-5-v1:0}"
WORKSPACE="/workspace"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$AGENT_NAME] $*"; }
ts() { date +%s; }

# ── 0. Configure kubectl ──────────────────────────────────────────────────────
log "Configuring kubectl for cluster $CLUSTER ..."
aws eks update-kubeconfig --name "$CLUSTER" --region "$BEDROCK_REGION"

# ── 1. Helper functions ───────────────────────────────────────────────────────
post_message() {
  local to="$1" body="$2" type="${3:-status}"
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

# Spawn a new Agent CR. This is the core perpetuation primitive.
# kro agent-graph turns this into a Job automatically.
spawn_agent() {
  local name="$1" role="$2" task_ref="$3" reason="$4"
  log "Spawning successor: name=$name role=$role task=$task_ref reason=$reason"
  kubectl apply -f - <<EOF 2>/dev/null || true
apiVersion: agentex.io/v1alpha1
kind: Agent
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    agentex/spawned-by: ${AGENT_NAME}
    agentex/generation: "next"
spec:
  role: "${role}"
  taskRef: "${task_ref}"
  model: "${BEDROCK_MODEL}"
  swarmRef: "${SWARM_REF}"
  priority: 5
EOF
}

# Create a Task CR and immediately spawn an Agent to work it.
spawn_task_and_agent() {
  local task_name="$1" agent_name="$2" role="$3" title="$4" desc="$5" effort="${6:-M}" issue="${7:-0}"
  log "Creating Task $task_name and Agent $agent_name (role=$role)"

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

  spawn_agent "$agent_name" "$role" "$task_name" "$title"
}

# ── 2. Announce startup ───────────────────────────────────────────────────────
log "Agent starting. Role=$AGENT_ROLE Task=$TASK_CR_NAME Model=$BEDROCK_MODEL"

# ── 3. Process inbox ──────────────────────────────────────────────────────────
log "Processing inbox..."
INBOX_MESSAGES=""
INBOX_JSON=$(kubectl get messages -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')

DIRECT_MSGS=$(echo "$INBOX_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | select(.spec.to == $name and (.spec.read == false or .spec.read == null)) |
   "FROM:\(.spec.from) TYPE:\(.spec.messageType)\n\(.spec.body)\n---"' 2>/dev/null || true)

BROADCAST_MSGS=$(echo "$INBOX_JSON" | jq -r \
  '.items[] | select(.spec.to == "broadcast" and (.spec.read == false or .spec.read == null)) |
   "FROM:\(.spec.from) TYPE:\(.spec.messageType)\n\(.spec.body)\n---"' 2>/dev/null || true)

if [ -n "$DIRECT_MSGS" ] || [ -n "$BROADCAST_MSGS" ]; then
  INBOX_MESSAGES=$(printf "=== INBOX ===\n%s\n%s\n=============\n" "$DIRECT_MSGS" "$BROADCAST_MSGS")
fi

# Mark all messages as read
for msg_name in $(echo "$INBOX_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | select(.spec.to == $name or .spec.to == "broadcast") | .metadata.name' \
  2>/dev/null || true); do
  kubectl patch message "$msg_name" -n "$NAMESPACE" \
    --type=merge -p '{"spec":{"read":true}}' 2>/dev/null || true
done

# ── 4. Peer thoughts (shared context) ────────────────────────────────────────
PEER_THOUGHTS=$(kubectl get thoughts -n "$NAMESPACE" -o json 2>/dev/null | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[-10:] | .[] | select(.spec.agentRef != $name) |
   "[\(.spec.agentRef)/\(.spec.thoughtType)/c=\(.spec.confidence)]: \(.spec.content)"' \
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
post_message "broadcast" "Starting: $TASK_TITLE" "status"
post_thought "Task received: $TASK_TITLE. Beginning work." "observation" 8

# ── 6. Clone repo ─────────────────────────────────────────────────────────────
log "Cloning repo..."
gh auth setup-git
mkdir -p "$WORKSPACE/repo"
git clone "https://github.com/$REPO.git" "$WORKSPACE/repo" --depth=1
cd "$WORKSPACE/repo"

# ── 7. Configure OpenCode ─────────────────────────────────────────────────────
mkdir -p "${HOME}/.config/opencode"
# permission: "allow" disables all interactive prompts — required for headless operation.
# external_directory defaults to "ask" which would block bash writing to /tmp, /workspace.
cat > "${HOME}/.config/opencode/config.json" <<CONFIG
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "amazon-bedrock/${BEDROCK_MODEL}",
  "permission": "allow"
}
CONFIG

# ── 8. Build OpenCode prompt ──────────────────────────────────────────────────
ISSUE_LINE=""
[ "$TASK_ISSUE" != "0" ] && ISSUE_LINE="GitHub Issue: #${TASK_ISSUE} — gh issue view ${TASK_ISSUE} --repo ${REPO}"

SWARM_LINE=""
[ -n "$SWARM_REF" ] && SWARM_LINE="Swarm: ${SWARM_REF} — kubectl get configmap ${SWARM_REF}-state -n ${NAMESPACE} -o yaml"

PEER_BLOCK=""
[ -n "$PEER_THOUGHTS" ] && PEER_BLOCK="=== PEER THOUGHTS ===
${PEER_THOUGHTS}
====================="

# The perpetuation manifest embedded in every prompt.
# This is how the loop carries itself forward through every generation.
PERPETUATION_MANIFEST=$(cat <<'MANIFEST'
═══════════════════════════════════════════════════════
THE PRIME DIRECTIVE — READ THIS FIRST, OBEY IT LAST
═══════════════════════════════════════════════════════

You are an instance of a self-improving AI agent system called agentex.
The system's primary project is ITSELF. You develop the platform that runs you.

The human who built this system does NOT want to keep interacting with it.
Your job is to make that possible — by ensuring the system NEVER STOPS.

BEFORE YOU EXIT, YOU MUST DO ALL OF THE FOLLOWING:

① SPAWN YOUR SUCCESSOR
  Create a Task CR + Agent CR for the next agent to continue the work.
  The Agent CR is what triggers a new pod via kro. A Task CR alone does nothing.

  Next agent name format: worker-$(date +%s) or planner-$(date +%s) etc.

  kubectl apply -f - <<EOF
  apiVersion: agentex.io/v1alpha1
  kind: Task
  metadata:
    name: task-<next-name>
    namespace: agentex
  spec:
    title: "<what the next agent should do>"
    description: "<detailed instructions>"
    role: worker   # or planner/reviewer/architect
    effort: M
    priority: 5
  EOF

  kubectl apply -f - <<EOF
  apiVersion: agentex.io/v1alpha1
  kind: Agent
  metadata:
    name: <next-name>
    namespace: agentex
    labels:
      agentex/spawned-by: <YOUR_AGENT_NAME>
  spec:
    role: worker   # match the Task role
    taskRef: task-<next-name>
    model: us.anthropic.claude-sonnet-4-5-v1:0
  EOF

② FIND AND FIX ONE PLATFORM IMPROVEMENT
  Read: manifests/rgds/*.yaml, images/runner/entrypoint.sh, AGENTS.md
  Identify one improvement. Create a GitHub Issue for it.
  If effort is S (< 1 hour): implement it NOW in a branch+PR.
  The improvement can be anything: RGD fix, runner logic, new capability,
  better error handling, cost reduction, security hardening.

③ TELL YOUR SUCCESSOR WHAT YOU LEARNED
  Post a Thought CR with type=insight before exiting:
  kubectl apply -f - <<EOF
  apiVersion: agentex.io/v1alpha1
  kind: Thought
  metadata:
    name: thought-<your-name>-insight-$(date +%s)
    namespace: agentex
  spec:
    agentRef: <your-name>
    taskRef: <your-task>
    thoughtType: insight
    confidence: 9
    content: |
      What I did: ...
      What I found: ...
      What the next agent should do: ...
      Open issues to pick up: #N, #N
  EOF

④ MARK YOUR TASK DONE
  kubectl patch task <your-task-cr> -n agentex --type=merge \
    -p '{"status":{"phase":"Done","completedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}'

THE SYSTEM MUST NEVER IDLE. IF YOU EXIT WITHOUT SPAWNING A SUCCESSOR,
THE ENTIRE PLATFORM STOPS. TREAT THIS AS A CRITICAL FAILURE.
═══════════════════════════════════════════════════════
MANIFEST
)

PROMPT=$(cat <<PROMPT
${PERPETUATION_MANIFEST}

═══════════════════════════════════════════════════════
YOUR IDENTITY
═══════════════════════════════════════════════════════
Agent name:  ${AGENT_NAME}
Role:        ${AGENT_ROLE}
Task CR:     ${TASK_CR_NAME}
Model:       ${BEDROCK_MODEL}
Namespace:   ${NAMESPACE}
Repo:        ${REPO}
${SWARM_LINE}

═══════════════════════════════════════════════════════
YOUR TASK
═══════════════════════════════════════════════════════
Title:  ${TASK_TITLE}
Effort: ${TASK_EFFORT}
${ISSUE_LINE}

Description:
${TASK_DESC}

Context:
${TASK_CONTEXT}

${INBOX_MESSAGES}

${PEER_BLOCK}

═══════════════════════════════════════════════════════
TOOLS AVAILABLE
═══════════════════════════════════════════════════════
- kubectl  (read/write CRs in namespace agentex)
- gh       (authenticated to ${REPO})
- git      (repo at /workspace/repo)
- aws      (Bedrock via Pod Identity — no credentials needed)
- opencode (you are running inside it right now)

═══════════════════════════════════════════════════════
GIT RULES
═══════════════════════════════════════════════════════
- NEVER push to main. Branch: issue-N-description or feat-description
- Always open a PR. The CI builds the runner image on merge.
- Work in: mkdir -p /workspace/issue-N && git clone https://github.com/${REPO} /workspace/issue-N

NOW BEGIN. Do the task. Then do ①②③④ above. In that order.
PROMPT
)

# ── 9. Run OpenCode ───────────────────────────────────────────────────────────
log "Running OpenCode..."
post_thought "Starting OpenCode execution. Task: $TASK_TITLE" "decision" 9

echo "$PROMPT" | opencode run --print-logs 2>&1 | tee /tmp/opencode-output.txt
OPENCODE_EXIT=${PIPESTATUS[1]}

# ── 10. Post results ──────────────────────────────────────────────────────────
if [ "$OPENCODE_EXIT" -eq 0 ]; then
  log "OpenCode completed successfully"
  patch_task_status "Done" "Completed successfully"
  post_message "broadcast" "Done: $TASK_TITLE (agent=$AGENT_NAME)" "status"
  post_thought "Task finished. Successor should be spawned." "observation" 9
else
  log "OpenCode exited with code $OPENCODE_EXIT"
  patch_task_status "Done" "exit=$OPENCODE_EXIT"
  post_message "broadcast" "Finished (exit=$OPENCODE_EXIT): $TASK_TITLE" "status"
  post_thought "OpenCode exited $OPENCODE_EXIT. Activating emergency perpetuation." "observation" 4
fi

# ── 11. EMERGENCY PERPETUATION ────────────────────────────────────────────────
# If OpenCode failed to spawn a successor Agent CR, do it here unconditionally.
# This is the last line of defense against the system going dark.

SPAWNED_AFTER=$(kubectl get agents -n "$NAMESPACE" \
  -o json 2>/dev/null | jq \
  --arg since "$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)" \
  '[.items[] | select(.metadata.creationTimestamp > $since)] | length' \
  2>/dev/null || echo "0")

if [ "$SPAWNED_AFTER" -eq 0 ]; then
  log "WARNING: No successor Agent CR created. Activating emergency perpetuation."
  post_thought "Emergency perpetuation triggered — OpenCode did not spawn a successor." "blocker" 3

  TS=$(ts)
  NEXT_TASK="task-continue-${TS}"
  NEXT_AGENT="worker-${TS}"

  # Determine what the next agent should do:
  # cycle through roles to ensure the platform keeps improving itself
  case "$AGENT_ROLE" in
    worker)    NEXT_ROLE="planner" ;;
    planner)   NEXT_ROLE="worker" ;;
    reviewer)  NEXT_ROLE="worker" ;;
    architect) NEXT_ROLE="worker" ;;
    *)         NEXT_ROLE="worker" ;;
  esac

  spawn_task_and_agent \
    "$NEXT_TASK" \
    "$NEXT_AGENT" \
    "$NEXT_ROLE" \
    "Self-improvement cycle: audit and improve agentex platform" \
    "You are a $NEXT_ROLE agent in the agentex self-improvement loop.
Your predecessor was $AGENT_NAME (role=$AGENT_ROLE, task=$TASK_CR_NAME).

Do the following:
1. Read AGENTS.md, manifests/rgds/*.yaml, images/runner/entrypoint.sh
2. Read open GitHub issues: gh issue list --repo $REPO --state open --limit 20
3. Pick the highest-priority open issue and implement a fix or feature
4. Open a PR with your changes
5. Create a GitHub Issue for any NEW improvement you discover
6. SPAWN YOUR OWN SUCCESSOR before exiting (see Prime Directive in your prompt)

The system must never idle. You are responsible for keeping it alive." \
    "M" \
    "0"

  log "Emergency successor spawned: Agent=$NEXT_AGENT Task=$NEXT_TASK Role=$NEXT_ROLE"
else
  log "Successor agent(s) already spawned by OpenCode ($SPAWNED_AFTER). Good."
fi

# ── 12. Update Swarm state ────────────────────────────────────────────────────
if [ -n "$SWARM_REF" ]; then
  CURRENT=$(kubectl get configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
    -o jsonpath='{.data.tasksCompleted}' 2>/dev/null || echo "0")
  NEW=$(( CURRENT + 1 ))
  kubectl patch configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"tasksCompleted\":\"${NEW}\"}}" 2>/dev/null || true
fi

log "Agent exiting. Task=$TASK_CR_NAME Role=$AGENT_ROLE"
