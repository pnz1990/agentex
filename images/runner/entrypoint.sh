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
BEDROCK_MODEL="${BEDROCK_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
WORKSPACE="/workspace"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$AGENT_NAME] $*"; }
ts() { date +%s; }

# ── 0. Validate critical environment variables ────────────────────────────────
# Fail fast if required variables are missing to prevent cascading silent failures
if [ -z "$TASK_CR_NAME" ]; then
  echo "[FATAL] TASK_CR_NAME is required but not set. Agent cannot proceed without a task assignment." >&2
  exit 1
fi

if [ -z "$AGENT_NAME" ] || [ "$AGENT_NAME" = "unknown" ]; then
  echo "[FATAL] AGENT_NAME is required but not set. Agent cannot proceed without an identity." >&2
  exit 1
fi

log "Environment validated: agent=$AGENT_NAME task=$TASK_CR_NAME role=$AGENT_ROLE"

# ── 1. Configure kubectl ──────────────────────────────────────────────────────
log "Configuring kubectl for cluster $CLUSTER ..."
aws eks update-kubeconfig --name "$CLUSTER" --region "$BEDROCK_REGION"

# ── 2. Helper functions ───────────────────────────────────────────────────────
post_message() {
  local to="$1" body="$2" type="${3:-status}"
  local msg_name="msg-${AGENT_NAME}-$(date +%s%3N)"
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local err_output
  err_output=$(kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Message
metadata:
  name: ${msg_name}
  namespace: ${NAMESPACE}
spec:
  from: "${AGENT_NAME}"
  to: "${to}"
  thread: "${TASK_CR_NAME}"
  messageType: "${type}"
  timestamp: "${timestamp}"
  body: |
$(echo "$body" | sed 's/^/    /')
EOF
) || {
    log "ERROR: Failed to create Message CR $msg_name: $err_output"
    return 0  # Don't fail the agent, but log the error
  }
  push_metric "MessageCreated" 1
}

post_thought() {
  local content="$1" type="${2:-observation}" confidence="${3:-7}"
  local thought_name="thought-${AGENT_NAME}-$(date +%s%3N)"
  local err_output
  err_output=$(kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
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
) || {
    log "ERROR: Failed to create Thought CR $thought_name: $err_output"
    return 0  # Don't fail the agent, but log the error
  }
  push_metric "ThoughtCreated" 1

  # Persist thought to S3 for long-term memory (survives cluster restarts)
  # Check if bucket exists before attempting write
  if aws s3 ls s3://agentex-thoughts/ >/dev/null 2>&1; then
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local s3_key="${AGENT_NAME}-${thought_name}.json"
    
    # Create JSON document with full thought metadata
    local s3_output
    if ! s3_output=$(cat <<JSON | aws s3 cp - "s3://agentex-thoughts/${s3_key}" --content-type application/json 2>&1
{
  "name": "${thought_name}",
  "agentRef": "${AGENT_NAME}",
  "taskRef": "${TASK_CR_NAME}",
  "thoughtType": "${type}",
  "confidence": ${confidence},
  "timestamp": "${timestamp}",
  "content": $(echo "$content" | jq -Rs .)
}
JSON
); then
      log "WARNING: Failed to persist thought to S3 (key=${s3_key}): ${s3_output}"
    fi
  fi
}

# post_report() - Report CR with parameters matching Prime Directive step ⑤
# This is the primary interface agents should use per Prime Directive.
post_report() {
  local vision_score="$1" work_done="$2" issues_found="${3:-}" pr_opened="${4:-}" blockers="${5:-}" next_priority="${6:-}" exit_code="${7:-0}"
  local report_name="report-${AGENT_NAME}-$(date +%s)"
  
  # Get agent's generation from Agent CR
  local generation=$(kubectl get agent "$AGENT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  if ! [[ "$generation" =~ ^[0-9]+$ ]]; then
    generation=0
  fi
  
  local err_output
  err_output=$(kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Report
metadata:
  name: ${report_name}
  namespace: ${NAMESPACE}
spec:
  agentRef: "${AGENT_NAME}"
  taskRef: "${TASK_CR_NAME}"
  role: "${AGENT_ROLE}"
  status: "completed"
  visionScore: ${vision_score}
  workDone: |
$(echo "$work_done" | sed 's/^/    /')
  issuesFound: "${issues_found}"
  prOpened: "${pr_opened}"
  blockers: "${blockers}"
  nextPriority: "${next_priority}"
  generation: ${generation}
  exitCode: ${exit_code}
EOF
) || {
    log "ERROR: Failed to create Report CR $report_name: $err_output"
    return 0  # Don't fail the agent, but log the error
  }
  push_metric "ReportCreated" 1
  log "Report filed: vision=$vision_score issues=$issues_found pr=$pr_opened"
}

patch_task_status() {
  local phase="$1" outcome="${2:-}"
  local completed_at=""
  [ "$phase" = "Done" ] && completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Patch the ConfigMap backing the Task CR, not the Task CR status directly.
  # kro status fields are output-only and reflect the ConfigMap data.
  kubectl patch configmap "${TASK_CR_NAME}-spec" -n "$NAMESPACE" \
    --type=merge \
    -p "{\"data\":{\"phase\":\"${phase}\",\"agentRef\":\"${AGENT_NAME}\",\"outcome\":\"${outcome}\",\"completedAt\":\"${completed_at}\"}}" \
    2>/dev/null || true
}

# Push a custom metric to CloudWatch for dashboard visibility.
# These metrics power the agentex-activity CloudWatch dashboard.
push_metric() {
  local metric_name="$1" value="${2:-1}" unit="${3:-Count}"
  aws cloudwatch put-metric-data \
    --namespace Agentex \
    --metric-name "$metric_name" \
    --value "$value" \
    --unit "$unit" \
    --dimensions Role="$AGENT_ROLE",Agent="$AGENT_NAME" \
    --region "$BEDROCK_REGION" \
    2>/dev/null || true
}

# ── Consensus Protocol Functions ──────────────────────────────────────────────
# These functions implement consensus voting via Thought CRs (issue #2).
# Agents can propose motions, vote on proposals, and check if consensus is reached.

# Propose a motion that requires consensus approval.
# Usage: propose_motion "motion-name" "Motion text" "3/5" "deadline-timestamp"
# Creates a Thought CR with thoughtType=proposal
propose_motion() {
  local motion_name="$1" motion_text="$2" threshold="$3" deadline="$4"
  local proposal_content="MOTION: ${motion_name}
THRESHOLD: ${threshold}
DEADLINE: ${deadline}
TEXT: ${motion_text}"
  
  post_thought "$proposal_content" "proposal" 9
  log "Consensus proposal created: $motion_name (threshold=$threshold deadline=$deadline)"
}

# Cast a vote on a consensus proposal.
# Usage: cast_vote "motion-name" "yes|no" "reason for vote"
# Creates a Thought CR with thoughtType=vote
cast_vote() {
  local motion_name="$1" vote="$2" reason="$3"
  local vote_content="MOTION: ${motion_name}
VOTE: ${vote}
REASON: ${reason}
CAST_BY: ${AGENT_NAME}"
  
  post_thought "$vote_content" "vote" 9
  log "Consensus vote cast: motion=$motion_name vote=$vote"
}

# Check if consensus has been reached for a proposal.
# Usage: check_consensus "motion-name" "3/5"
# Returns: "yes" (consensus reached), "no" (consensus failed), "pending" (still open)
# Optionally posts a verdict Thought CR if threshold is met
check_consensus() {
  local motion_name="$1" threshold="$2"
  local required_yes="${threshold%/*}"
  local total_votes="${threshold#*/}"
  
  # Get all proposal and vote Thoughts for this motion
  local thoughts_json=$(kubectl get thoughts -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
  
  # Find the proposal
  local proposal=$(echo "$thoughts_json" | jq -r \
    --arg motion "$motion_name" \
    '.items[] | select(.spec.thoughtType == "proposal" and (.spec.content | contains("MOTION: " + $motion))) | 
     .metadata.name' | head -1)
  
  if [ -z "$proposal" ]; then
    log "Consensus check: motion '$motion_name' not found"
    echo "pending"
    return 0
  fi
  
  # Count yes and no votes
  local yes_votes=$(echo "$thoughts_json" | jq -r \
    --arg motion "$motion_name" \
    '.items[] | select(.spec.thoughtType == "vote" and (.spec.content | contains("MOTION: " + $motion) and contains("VOTE: yes"))) | 
     .spec.agentRef' | wc -l)
  
  local no_votes=$(echo "$thoughts_json" | jq -r \
    --arg motion "$motion_name" \
    '.items[] | select(.spec.thoughtType == "vote" and (.spec.content | contains("MOTION: " + $motion) and contains("VOTE: no"))) | 
     .spec.agentRef' | wc -l)
  
  log "Consensus check: motion=$motion_name yes=$yes_votes no=$no_votes threshold=$threshold"
  
  # Check if consensus threshold is met
  if [ "$yes_votes" -ge "$required_yes" ]; then
    # Post verdict Thought if not already posted
    local existing_verdict=$(echo "$thoughts_json" | jq -r \
      --arg motion "$motion_name" \
      '.items[] | select(.spec.thoughtType == "verdict" and (.spec.content | contains("MOTION: " + $motion))) | 
       .metadata.name' | head -1)
    
    if [ -z "$existing_verdict" ]; then
      local verdict_content="MOTION: ${motion_name}
RESULT: APPROVED
YES_VOTES: ${yes_votes}
NO_VOTES: ${no_votes}
THRESHOLD: ${threshold}
TALLIED_BY: ${AGENT_NAME}
TALLIED_AT: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      post_thought "$verdict_content" "verdict" 10
      log "Consensus REACHED: motion=$motion_name approved with $yes_votes/$total_votes votes"
    fi
    echo "yes"
    return 0
  fi
  
  # Check if consensus is impossible (too many no votes)
  local remaining_voters=$((total_votes - yes_votes - no_votes))
  local max_possible_yes=$((yes_votes + remaining_voters))
  
  if [ "$max_possible_yes" -lt "$required_yes" ]; then
    # Post rejection verdict if not already posted
    local existing_verdict=$(echo "$thoughts_json" | jq -r \
      --arg motion "$motion_name" \
      '.items[] | select(.spec.thoughtType == "verdict" and (.spec.content | contains("MOTION: " + $motion))) | 
       .metadata.name' | head -1)
    
    if [ -z "$existing_verdict" ]; then
      local verdict_content="MOTION: ${motion_name}
RESULT: REJECTED
YES_VOTES: ${yes_votes}
NO_VOTES: ${no_votes}
THRESHOLD: ${threshold}
TALLIED_BY: ${AGENT_NAME}
TALLIED_AT: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      post_thought "$verdict_content" "verdict" 10
      log "Consensus FAILED: motion=$motion_name rejected (impossible to reach threshold)"
    fi
    echo "no"
    return 0
  fi
  
  log "Consensus PENDING: motion=$motion_name (need $required_yes yes votes, have $yes_votes)"
  echo "pending"
  return 0
}

# Spawn a new Agent CR. This is the core perpetuation primitive.
# kro agent-graph turns this into a Job automatically.
spawn_agent() {
  local name="$1" role="$2" task_ref="$3" reason="$4"
  
  # Calculate next generation number by reading current agent's generation label
  local my_generation=$(kubectl get agent "$AGENT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  # Handle non-numeric generation (e.g., "next" from old code) by defaulting to 0
  if ! [[ "$my_generation" =~ ^[0-9]+$ ]]; then
    my_generation=0
  fi
  local next_generation=$((my_generation + 1))
  
  log "Spawning successor: name=$name role=$role task=$task_ref gen=$next_generation reason=$reason"
  local err_output
  err_output=$(kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    agentex/spawned-by: ${AGENT_NAME}
    agentex/generation: "${next_generation}"
spec:
  role: "${role}"
  taskRef: "${task_ref}"
  model: "${BEDROCK_MODEL}"
  swarmRef: "${SWARM_REF}"
  priority: 5
EOF
) || {
    log "ERROR: CRITICAL - Failed to create Agent CR $name: $err_output"
    log "ERROR: System perpetuation may be broken. Emergency spawn may trigger."
    return 0  # Don't fail immediately - let emergency spawn handle it
  }
}

# Create a Task CR and immediately spawn an Agent to work it.
spawn_task_and_agent() {
  local task_name="$1" agent_name="$2" role="$3" title="$4" desc="$5" effort="${6:-M}" issue="${7:-0}"
  log "Creating Task $task_name and Agent $agent_name (role=$role)"

  local err_output
  err_output=$(kubectl apply -f - <<EOF 2>&1
apiVersion: kro.run/v1alpha1
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
) || {
    log "ERROR: Failed to create Task CR $task_name: $err_output"
    log "ERROR: Will still attempt to spawn Agent (may fail without Task)"
  }
  push_metric "TaskCreated" 1
  spawn_agent "$agent_name" "$role" "$task_name" "$title"
}

# ── 3. Announce startup ───────────────────────────────────────────────────────
log "Agent starting. Role=$AGENT_ROLE Task=$TASK_CR_NAME Model=$BEDROCK_MODEL"
push_metric "AgentRun" 1

# ── 4. Process inbox ──────────────────────────────────────────────────────────
log "Processing inbox..."
INBOX_MESSAGES=""
INBOX_JSON=$(kubectl get messages -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')

DIRECT_MSGS=$(echo "$INBOX_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | select(.spec.to == $name and (.status.read == "false" or .status.read == null)) |
   "FROM:\(.spec.from) TYPE:\(.spec.messageType)\n\(.spec.body)\n---"' 2>/dev/null || true)

BROADCAST_MSGS=$(echo "$INBOX_JSON" | jq -r \
  '.items[] | select(.spec.to == "broadcast" and (.status.read == "false" or .status.read == null)) |
   "FROM:\(.spec.from) TYPE:\(.spec.messageType)\n\(.spec.body)\n---"' 2>/dev/null || true)

if [ -n "$DIRECT_MSGS" ] || [ -n "$BROADCAST_MSGS" ]; then
  INBOX_MESSAGES=$(printf "=== INBOX ===\n%s\n%s\n=============\n" "$DIRECT_MSGS" "$BROADCAST_MSGS")
fi

# Mark all unread messages as read by patching the ConfigMap backing each Message CR
for msg_name in $(echo "$INBOX_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | select((.spec.to == $name or .spec.to == "broadcast") and (.status.read == "false" or .status.read == null)) | .metadata.name' \
  2>/dev/null || true); do
  # Patch the ConfigMap, not the Message CR. kro status fields are output-only.
  kubectl patch configmap "${msg_name}-msg" -n "$NAMESPACE" \
    --type=merge -p '{"data":{"read":"true"}}' 2>/dev/null || true
done

# ── 5. Peer thoughts (shared context) ────────────────────────────────────────
# Get the last 10 thoughts from other agents, excluding ones we've already read
# CRITICAL: Must sort by creationTimestamp to get the actual LAST 10 thoughts
# Bug #89: .items[-10:] on unsorted output may return random 10, not the latest 10
THOUGHTS_JSON=$(kubectl get thoughts -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp -o json 2>/dev/null || echo '{"items":[]}')
PEER_THOUGHTS=$(echo "$THOUGHTS_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[-10:] | .[] | 
   select(.spec.agentRef != $name) |
   select((.status.readBy // "" | contains($name)) == false) |
   "[\(.spec.agentRef)/\(.spec.thoughtType)/c=\(.spec.confidence)]: \(.spec.content)"' \
  2>/dev/null || true)

# Mark thoughts as read by this agent (patch ConfigMap backing the Thought CR)
for thought_name in $(echo "$THOUGHTS_JSON" | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[-10:] | .[] | 
   select(.spec.agentRef != $name) |
   select((.status.readBy // "" | contains($name)) == false) |
   .metadata.name' \
  2>/dev/null || true); do
  # Get current readBy value from ConfigMap and append this agent's name
  CURRENT_READ_BY=$(kubectl get configmap "${thought_name}-thought" -n "$NAMESPACE" \
    -o jsonpath='{.data.readBy}' 2>/dev/null || echo "")
  if [ -z "$CURRENT_READ_BY" ]; then
    NEW_READ_BY="$AGENT_NAME"
  else
    NEW_READ_BY="${CURRENT_READ_BY},${AGENT_NAME}"
  fi
  kubectl patch configmap "${thought_name}-thought" -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"readBy\":\"${NEW_READ_BY}\"}}" 2>/dev/null || true
done

# ── 4b. S3 Historical Thoughts (long-term memory) ─────────────────────────────
# Supplement in-cluster thoughts with recent historical thoughts from S3
# This provides context across cluster restarts and preserves institutional memory
if aws s3 ls s3://agentex-thoughts/ >/dev/null 2>&1; then
  S3_THOUGHTS=""
  
  # Get the 20 most recent thought files from S3 (sorted by modification time)
  S3_FILES=$(aws s3 ls s3://agentex-thoughts/ --recursive 2>/dev/null | \
    sort -k1,2 | tail -20 | awk '{print $4}' || true)
  
  # Read each thought file and format for display (exclude our own thoughts)
  for s3_key in $S3_FILES; do
    THOUGHT_DATA=$(aws s3 cp "s3://agentex-thoughts/${s3_key}" - 2>/dev/null || echo "{}")
    
    # Extract fields and format like in-cluster thoughts
    THOUGHT_AGENT=$(echo "$THOUGHT_DATA" | jq -r '.agentRef // "unknown"' 2>/dev/null || echo "unknown")
    
    # Skip our own thoughts
    if [ "$THOUGHT_AGENT" != "$AGENT_NAME" ]; then
      THOUGHT_TYPE=$(echo "$THOUGHT_DATA" | jq -r '.thoughtType // "observation"' 2>/dev/null || echo "observation")
      THOUGHT_CONF=$(echo "$THOUGHT_DATA" | jq -r '.confidence // 7' 2>/dev/null || echo "7")
      THOUGHT_CONTENT=$(echo "$THOUGHT_DATA" | jq -r '.content // ""' 2>/dev/null || echo "")
      
      if [ -n "$THOUGHT_CONTENT" ]; then
        S3_THOUGHTS="${S3_THOUGHTS}[${THOUGHT_AGENT}/${THOUGHT_TYPE}/c=${THOUGHT_CONF}] (S3): ${THOUGHT_CONTENT}
"
      fi
    fi
  done
  
  # Combine in-cluster and S3 thoughts (prioritize in-cluster as they're more recent)
  if [ -n "$S3_THOUGHTS" ]; then
    if [ -n "$PEER_THOUGHTS" ]; then
      PEER_THOUGHTS="${PEER_THOUGHTS}

=== S3 HISTORICAL CONTEXT ===
${S3_THOUGHTS}"
    else
      PEER_THOUGHTS="=== S3 HISTORICAL CONTEXT ===
${S3_THOUGHTS}"
    fi
  fi
fi

# ── 6. Read Task CR ───────────────────────────────────────────────────────────
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

# ── 7. Clone repo ─────────────────────────────────────────────────────────────
log "Cloning repo..."
gh auth setup-git
mkdir -p "$WORKSPACE/repo"
git clone "https://github.com/$REPO.git" "$WORKSPACE/repo" --depth=1
cd "$WORKSPACE/repo"

# ── 8. Configure OpenCode ─────────────────────────────────────────────────────
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

# ── 9. Build OpenCode prompt ──────────────────────────────────────────────────
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
  apiVersion: kro.run/v1alpha1
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

  # IMPORTANT: Agent CRs must use kro.run/v1alpha1 (NOT agentex.io/v1alpha1)
  # kro watches kro.run group to trigger Jobs. agentex.io is a dead CRD.
  kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
  kind: Agent
  metadata:
    name: <next-name>
    namespace: agentex
    labels:
      agentex/spawned-by: <YOUR_AGENT_NAME>
  spec:
    role: worker   # match the Task role
    taskRef: task-<next-name>
    model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
  EOF

② FIND AND FIX ONE PLATFORM IMPROVEMENT
  Read: manifests/rgds/*.yaml, images/runner/entrypoint.sh, AGENTS.md
  Identify one improvement. Create a GitHub Issue for it.
  If effort is S (< 1 hour): implement it NOW in a branch+PR.
  The improvement can be anything: RGD fix, runner logic, new capability,
  better error handling, cost reduction, security hardening.

  ROLE ESCALATION: If you discover a structural/architectural problem with
  the platform (RGD bugs, kro issues, system design flaws), post a Thought CR
  with thoughtType=blocker mentioning "structural" or "architecture". The
  runner will automatically escalate your successor to architect role.

③ TELL YOUR SUCCESSOR WHAT YOU LEARNED
  Post a Thought CR with type=insight before exiting:
  kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
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
  kubectl patch configmap <your-task-cr>-spec -n agentex --type=merge \
    -p '{"data":{"phase":"Done","completedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}'

⑤ FILE YOUR REPORT (the god-observer reads these to steer the civilization)
  kubectl apply -f - <<EOF
  apiVersion: kro.run/v1alpha1
  kind: Report
  metadata:
    name: report-<your-name>-$(date +%s)
    namespace: agentex
  spec:
    agentRef: <your-name>
    taskRef: <your-task>
    role: <your-role>
    status: completed
    visionScore: <1-10: how aligned was your work with the long-term vision?>
    workDone: |
      - <bullet: what you accomplished>
    issuesFound: "#N, #N"
    prOpened: "PR #N"
    blockers: "<anything blocking the civilization>"
    nextPriority: "<what the next agent should prioritize>"
    generation: <your generation number from Agent CR label agentex/generation>
    exitCode: 0
  EOF

  visionScore guide: 10=consensus/swarms/memory, 7=role escalation/dashboard,
  5=platform stability, 3=bug fixes only, 1=emergency perpetuation only.

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

# ── 10. Run OpenCode ───────────────────────────────────────────────────────────
log "Running OpenCode..."
post_thought "Starting OpenCode execution. Task: $TASK_TITLE" "decision" 9

echo "$PROMPT" | opencode run --print-logs 2>&1 | tee /tmp/opencode-output.txt
OPENCODE_EXIT=${PIPESTATUS[1]}

# ── 11. Post results ──────────────────────────────────────────────────────────
if [ "$OPENCODE_EXIT" -eq 0 ]; then
  log "OpenCode completed successfully"
  patch_task_status "Done" "Completed successfully"
  post_message "broadcast" "Done: $TASK_TITLE (agent=$AGENT_NAME)" "status"
  post_thought "Task finished. Successor should be spawned." "observation" 9
  file_report "completed" "$TASK_TITLE completed successfully" "none" 8
else
  log "OpenCode exited with code $OPENCODE_EXIT"
  patch_task_status "Done" "exit=$OPENCODE_EXIT"
  post_message "broadcast" "Finished (exit=$OPENCODE_EXIT): $TASK_TITLE" "status"
  post_thought "OpenCode exited $OPENCODE_EXIT. Activating emergency perpetuation." "observation" 4
  push_metric "AgentFailure" 1
  file_report "failed" "Agent failed with exit code $OPENCODE_EXIT" "Agent execution failure" 3
fi

# ── 11.5. ROLE ESCALATION ─────────────────────────────────────────────────────
# Check if this agent discovered a structural issue that requires architect-level intervention.
# If so, the successor should be spawned with role=architect instead of the default role.
ESCALATED_ROLE=""

# Check all Thought CRs posted by THIS agent during this run for structural blockers
BLOCKER_THOUGHTS=$(kubectl get thoughts -n "$NAMESPACE" \
  -l "agentex/agent=$AGENT_NAME" \
  -o json 2>/dev/null | jq -r \
  --arg name "$AGENT_NAME" \
  '.items[] | 
   select(.spec.agentRef == $name and .spec.thoughtType == "blocker") |
   .spec.content' 2>/dev/null || true)

# Look for keywords that indicate structural problems requiring architecture changes
if echo "$BLOCKER_THOUGHTS" | grep -qiE '(structural|architecture|RGD|kro.*bug|system.*design|breaking.*change)'; then
  log "ROLE ESCALATION TRIGGERED: Structural issue detected in blocker thoughts"
  ESCALATED_ROLE="architect"
  post_thought "Role escalation triggered: worker → architect (structural issue found)" "decision" 9
  post_message "broadcast" "Role escalation: $AGENT_NAME discovered structural issue, next agent will be architect" "status"
fi

# ── 12. EMERGENCY PERPETUATION ────────────────────────────────────────────────
# If OpenCode failed to spawn a successor Agent CR, do it here unconditionally.
# This is the last line of defense against the system going dark.

# Check if THIS agent spawned a successor by filtering on the spawned-by label.
# This is precise and avoids false positives from other agents' spawns.
SUCCESSOR_AGENTS=$(kubectl get agents.kro.run -n "$NAMESPACE" \
  -l "agentex/spawned-by=$AGENT_NAME" \
  -o json 2>/dev/null || echo '{"items":[]}')
SPAWNED_BY_ME=$(echo "$SUCCESSOR_AGENTS" | jq '.items | length' 2>/dev/null || echo "0")

NEEDS_EMERGENCY_SPAWN=false
EMERGENCY_REASON=""

if [ "$SPAWNED_BY_ME" -eq 0 ]; then
  log "WARNING: No successor Agent CR created. Activating emergency perpetuation."
  NEEDS_EMERGENCY_SPAWN=true
  EMERGENCY_REASON="No Agent CR created"
  post_thought "Emergency perpetuation triggered — OpenCode did not spawn a successor." "blocker" 3
else
  # Agent CR(s) exist, but verify kro actually created Job(s) for them
  # Issue #54: Agent CR can exist but kro may fail to create the Job
  log "Found $SPAWNED_BY_ME successor Agent CR(s). Verifying Jobs were created by kro..."
  
  JOBS_VERIFIED=0
  for agent_name in $(echo "$SUCCESSOR_AGENTS" | jq -r '.items[].metadata.name' 2>/dev/null || true); do
    # Check if Agent CR has status.jobName populated by kro
    JOB_NAME=$(kubectl get agent "$agent_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.jobName}' 2>/dev/null || echo "")
    
    if [ -z "$JOB_NAME" ]; then
      log "WARNING: Agent CR $agent_name exists but status.jobName is empty (kro hasn't processed it yet)"
      # Give kro a moment to process the Agent CR (it may be in progress)
      sleep 5
      JOB_NAME=$(kubectl get agent "$agent_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.jobName}' 2>/dev/null || echo "")
    fi
    
    if [ -z "$JOB_NAME" ]; then
      log "ERROR: Agent CR $agent_name still has no Job after 5s wait. kro may be down or RGD is broken."
      NEEDS_EMERGENCY_SPAWN=true
      EMERGENCY_REASON="Agent CR exists but kro didn't create Job (kro down or RGD error)"
      post_thought "Critical: Agent CR $agent_name created but kro failed to create Job. Possible kro failure or RGD syntax error." "blocker" 2
      break
    fi
    
    # Verify the Job actually exists
    if kubectl get job "$JOB_NAME" -n "$NAMESPACE" &>/dev/null; then
      log "✓ Agent CR $agent_name → Job $JOB_NAME exists"
      JOBS_VERIFIED=$((JOBS_VERIFIED + 1))
    else
      log "ERROR: Agent CR $agent_name has status.jobName=$JOB_NAME but Job doesn't exist"
      NEEDS_EMERGENCY_SPAWN=true
      EMERGENCY_REASON="Job referenced by Agent CR doesn't exist"
      post_thought "Critical: Agent CR $agent_name references Job $JOB_NAME but Job not found. kro may have failed." "blocker" 2
      break
    fi
  done
  
  if [ "$JOBS_VERIFIED" -gt 0 ] && [ "$NEEDS_EMERGENCY_SPAWN" = false ]; then
    log "Successor verification passed: $JOBS_VERIFIED Job(s) confirmed. No emergency perpetuation needed."
  fi
fi

if [ "$NEEDS_EMERGENCY_SPAWN" = true ]; then
  log "EMERGENCY PERPETUATION ACTIVATED: $EMERGENCY_REASON"

  TS=$(ts)
  NEXT_TASK="task-continue-${TS}"
  NEXT_AGENT="worker-${TS}"

  # Determine what the next agent should do:
  # If role escalation was triggered, use that; otherwise cycle through roles
  if [ -n "$ESCALATED_ROLE" ]; then
    NEXT_ROLE="$ESCALATED_ROLE"
    log "Using escalated role: $NEXT_ROLE"
  else
    # Default role cycling to ensure the platform keeps improving itself
    case "$AGENT_ROLE" in
      worker)    NEXT_ROLE="planner" ;;
      planner)   NEXT_ROLE="worker" ;;
      reviewer)  NEXT_ROLE="worker" ;;
      architect) NEXT_ROLE="worker" ;;
      *)         NEXT_ROLE="worker" ;;
    esac
  fi

  # CONSENSUS CHECK (issue #2): Prevent runaway agent proliferation
  # Count running agents of the same role. If >= 3, require consensus before spawning.
  RUNNING_AGENTS=$(kubectl get agents.kro.run -n "$NAMESPACE" -o json 2>/dev/null | \
    jq --arg role "$NEXT_ROLE" '[.items[] | select(.spec.role == $role)] | length' 2>/dev/null || echo "0")
  
  CONSENSUS_REQUIRED=false
  if [ "$RUNNING_AGENTS" -ge 3 ]; then
    log "Consensus check: $RUNNING_AGENTS agents with role=$NEXT_ROLE already exist"
    CONSENSUS_REQUIRED=true
    
    # Check if a proposal already exists for spawning more agents of this role
    MOTION_NAME="spawn-more-${NEXT_ROLE}-agents"
    CONSENSUS_RESULT=$(check_consensus "$MOTION_NAME" "3/5")
    
    if [ "$CONSENSUS_RESULT" = "yes" ]; then
      log "Consensus APPROVED: spawn additional $NEXT_ROLE agent"
    elif [ "$CONSENSUS_RESULT" = "no" ]; then
      log "Consensus REJECTED: NOT spawning additional $NEXT_ROLE agent (proliferation prevented)"
      post_thought "Emergency spawn blocked by consensus: $RUNNING_AGENTS $NEXT_ROLE agents already running, consensus rejected spawning more." "blocker" 5
      # Don't spawn - consensus rejected it
      NEEDS_EMERGENCY_SPAWN=false
    else
      # Consensus pending - create proposal and vote yes (this agent believes it's necessary)
      log "Consensus PENDING: creating proposal for spawning $NEXT_ROLE agent"
      DEADLINE=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
      propose_motion "$MOTION_NAME" \
        "Emergency spawn of $NEXT_ROLE agent because: $EMERGENCY_REASON. Currently $RUNNING_AGENTS agents exist with this role." \
        "3/5" \
        "$DEADLINE"
      cast_vote "$MOTION_NAME" "yes" "This agent ($AGENT_NAME) needs a successor to maintain platform liveness."
      
      log "Consensus proposal created. Spawning anyway (urgent: maintain liveness)."
      # Note: We spawn anyway in this case because maintaining liveness is critical.
      # Other agents can vote and future spawns will see the consensus result.
    fi
  fi

  if [ "$NEEDS_EMERGENCY_SPAWN" = true ]; then
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

    if [ "$CONSENSUS_REQUIRED" = true ]; then
      log "Emergency successor spawned (with consensus check): Agent=$NEXT_AGENT Task=$NEXT_TASK Role=$NEXT_ROLE Running=${RUNNING_AGENTS} Reason=$EMERGENCY_REASON"
    else
      log "Emergency successor spawned: Agent=$NEXT_AGENT Task=$NEXT_TASK Role=$NEXT_ROLE Reason=$EMERGENCY_REASON"
    fi
  fi
fi

# ── 13. Update Swarm state ────────────────────────────────────────────────────
if [ -n "$SWARM_REF" ]; then
  CURRENT=$(kubectl get configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
    -o jsonpath='{.data.tasksCompleted}' 2>/dev/null || echo "0")
  NEW=$(( CURRENT + 1 ))
  kubectl patch configmap "${SWARM_REF}-state" -n "$NAMESPACE" \
    --type=merge -p "{\"data\":{\"tasksCompleted\":\"${NEW}\"}}" 2>/dev/null || true
fi

log "Agent exiting. Task=$TASK_CR_NAME Role=$AGENT_ROLE"
