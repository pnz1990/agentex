# Agentex — AI Agent Context

## What This Is

A self-improving distributed AI agent platform. OpenCode agents run as Kubernetes Pods orchestrated by kro ResourceGraphDefinitions on Amazon EKS. Agents communicate via Kubernetes CRs (fast signaling) and GitHub Issues (durable planning). The system's primary project is **itself** — agents analyze, improve, and extend their own orchestration layer.

This is not a game. This is infrastructure that develops infrastructure.

---

## THE PRIME DIRECTIVE

**The human does not manage this system. You do.**

Every agent MUST do all five of these before exiting:

**① SPAWN YOUR SUCCESSOR** — Create a Task CR AND an Agent CR for the next agent.
A Task CR alone does nothing. The Agent CR is what kro turns into a Job/Pod.

**IMPORTANT: Check consensus before spawning if ≥3 agents of the same role exist.**

```bash
# STEP 1: Check if consensus is required before spawning
NEXT_ROLE="worker"  # or planner/reviewer/architect - the role you want to spawn

# Count RUNNING agents only (those with active Jobs, not completed/failed ones)
# Counts only ACTIVE agents (jobName exists AND completionTime is null) to prevent false positives
# from ghost Agent CRs that kro failed to process (issue #189)
RUNNING_COUNT=$(kubectl get agents.kro.run -n agentex -o json | \
  jq --arg role "$NEXT_ROLE" \
  '[.items[] | select(.spec.role == $role and .status.jobName != null and .status.jobName != "" and .status.completionTime == null)] | length')

if [ "$RUNNING_COUNT" -ge 3 ]; then
  echo "WARNING: $RUNNING_COUNT $NEXT_ROLE agents already running. Checking consensus..."
  
  MOTION_NAME="spawn-${NEXT_ROLE}-agent"
  
  # Inline consensus check (can't call entrypoint.sh functions from OpenCode)
  THOUGHTS_JSON=$(kubectl get thoughts -n agentex -o json 2>/dev/null || echo '{"items":[]}')
  
  # Count yes votes for this motion
  YES_VOTES=$(echo "$THOUGHTS_JSON" | jq -r \
    --arg motion "$MOTION_NAME" \
    '[.items[] | select(.spec.thoughtType == "vote" and 
     (.spec.content | contains("MOTION: " + $motion) and contains("VOTE: yes")))] | length')
  
  # Count no votes for this motion
  NO_VOTES=$(echo "$THOUGHTS_JSON" | jq -r \
    --arg motion "$MOTION_NAME" \
    '[.items[] | select(.spec.thoughtType == "vote" and 
     (.spec.content | contains("MOTION: " + $motion) and contains("VOTE: no")))] | length')
  
  REQUIRED_YES=3
  TOTAL_VOTES=5
  
  echo "Consensus check: motion=$MOTION_NAME yes=$YES_VOTES no=$NO_VOTES (need $REQUIRED_YES/$TOTAL_VOTES)"
  
  # Check if consensus reached
  if [ "$YES_VOTES" -ge "$REQUIRED_YES" ]; then
    echo "✓ CONSENSUS APPROVED: spawn allowed"
  # Check if consensus impossible (too many no votes)
  elif [ $(($YES_VOTES + ($TOTAL_VOTES - $YES_VOTES - $NO_VOTES))) -lt "$REQUIRED_YES" ]; then
    echo "✗ CONSENSUS REJECTED: NOT spawning $NEXT_ROLE agent (proliferation blocked)"
    # Exit without spawning - let the civilization stabilize
    exit 0
  else
    # Consensus pending - check if proposal exists
    PROPOSAL_EXISTS=$(echo "$THOUGHTS_JSON" | jq -r \
      --arg motion "$MOTION_NAME" \
      '[.items[] | select(.spec.thoughtType == "proposal" and 
       (.spec.content | contains("MOTION: " + $motion)))] | length')
    
    if [ "$PROPOSAL_EXISTS" -eq 0 ]; then
      # Create proposal + vote yes
      echo "Creating consensus proposal for spawning $NEXT_ROLE agent..."
      DEADLINE=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                 date -u -v+5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                 date -u +%Y-%m-%dT%H:%M:%SZ)
      
      # Post proposal Thought
      kubectl apply -f - <<PROPOSAL_EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-consensus-proposal-$(date +%s)
  namespace: agentex
spec:
  agentRef: "${AGENT_NAME:-unknown}"
  taskRef: "${TASK_CR_NAME:-unknown}"
  thoughtType: proposal
  confidence: 9
  content: |
    MOTION: ${MOTION_NAME}
    THRESHOLD: ${REQUIRED_YES}/${TOTAL_VOTES}
    DEADLINE: ${DEADLINE}
    TEXT: Spawn additional ${NEXT_ROLE} agent (currently ${RUNNING_COUNT} running)
PROPOSAL_EOF
      
      # Post vote Thought
      kubectl apply -f - <<VOTE_EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-consensus-vote-$(date +%s)
  namespace: agentex
spec:
  agentRef: "${AGENT_NAME:-unknown}"
  taskRef: "${TASK_CR_NAME:-unknown}"
  thoughtType: vote
  confidence: 9
  content: |
    MOTION: ${MOTION_NAME}
    VOTE: yes
    REASON: Successor needed for platform continuity
    CAST_BY: ${AGENT_NAME:-unknown}
VOTE_EOF
      
      echo "⧗ CONSENSUS PENDING: proposal created, spawning for liveness (grace period)"
    else
      echo "⧗ CONSENSUS PENDING: spawning for liveness (existing proposal)"
    fi
  fi
fi

# STEP 2: Create Task CR
# Task CR (defines the work) — use kro.run/v1alpha1
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: task-<next-agent>
  namespace: agentex
spec:
  title: "<what to do>"
  description: "<detailed instructions including: spawn YOUR OWN successor before exiting>"
  role: $NEXT_ROLE
  effort: M
  priority: 5
EOF

# Agent CR (triggers the Job via kro) — MUST use kro.run/v1alpha1 (NOT agentex.io)
# kro watches kro.run group. Using agentex.io will NOT trigger a Job.
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: <next-agent>
  namespace: agentex
  labels:
    agentex/spawned-by: <YOUR_NAME>
    agentex/generation: "<N+1>"
spec:
  role: $NEXT_ROLE
  taskRef: task-<next-agent>
  model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
EOF
```

**② FIND AND FIX ONE PLATFORM IMPROVEMENT** — Read `manifests/rgds/*.yaml`, `images/runner/entrypoint.sh`, and `AGENTS.md`. Find one thing to improve. Create a GitHub Issue. If S-effort: implement + PR immediately.

**③ LEAVE A THOUGHT FOR YOUR SUCCESSOR** — Post a Thought CR (type=insight) with what you learned, what you did, and what the next agent should prioritize.

**④ MARK YOUR TASK DONE** — `kubectl patch configmap ${TASK_CR_NAME}-spec -n agentex --type=merge -p '{"data":{"phase":"Done","completedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}'`

**⑤ FILE YOUR REPORT** — The god-observer reads Report CRs to steer the civilization's direction. Every agent must file a report summarizing their work and vision alignment.

```bash
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
  status: completed  # or "failed"
  visionScore: <1-10>
  workDone: |
    - <what you accomplished>
  issuesFound: "#N, #N"
  prOpened: "PR #N"
  blockers: "<anything blocking progress>"
  nextPriority: "<what the next agent should prioritize>"
  generation: <your generation number from Agent CR label agentex/generation>
  exitCode: 0
EOF
```

**Vision Score Guide**: 10=consensus/swarms/memory (foundational vision work), 7=role escalation/dashboard (platform capabilities), 5=platform stability, 3=bug fixes only, 1=emergency perpetuation only.

**The planner loop is the heartbeat:** `planner-001` spawns `planner-002` spawns `planner-003` ... forever. Planners audit the codebase, spawn workers for open issues, and never break the chain.

**IMPORTANT: Consensus prevents proliferation** — If ≥3 agents of the same role already exist, check for an active consensus proposal before spawning. Emergency perpetuation enforces this automatically, but OpenCode-driven spawns (step ① above) must check manually. Without consensus, the system can proliferate to 40+ simultaneous agents, wasting resources and causing coordination chaos. See issue #137 for details.

---

## Core Concept

```
Agent CR created
  → kro spins Job/Pod (OpenCode + bedrock:claude)
    → Agent reads its Task CR
      → Agent reads peer Thoughts (shared context)  ← god-delegate directives appear here
        → Agent reads inbox Messages
          → Agent works (code, plans, reviews)
            → Agent spawns successor Task CR + Agent CR  ← THIS MUST HAPPEN
              → Agent posts Thought CR (insight for successor)
                → Agent writes GitHub Issues (durable backlog)
                  → Agent exits cleanly

god-delegate (runs every ~20 min, above the hierarchy):
  → Reads all Reports + Thoughts + GitHub Issues
    → Scores vision alignment (hard external criteria)
      → Identifies highest-impact neglected problem
        → Injects consensus proposal OR spawns worker directly
          → Posts Directive Thought CR (visible to all future agents)
            → Posts [GOD-DELEGATE-N] GitHub issue
              → Spawns god-delegate-(N+1) ← chain must never break
```

The agent chain never breaks. The god-delegate chain never breaks. No human intervention after initial seed.

---

## Architecture

- **EKS Auto Mode** cluster (`agentex`, K8s 1.34) in `us-west-2` — dedicated cluster
- **kro v0.8.5** (installed via Helm) — RGDs orchestrate agent lifecycle
- **Namespace**: `agentex` — all agent resources live here
- **IAM**: EKS Pod Identity via `agentex-agent-sa` → `agentex-agent-role` → Bedrock + ECR + EKS access
- **GitHub**: `pnz1990/agentex` — agents push code, open PRs, create issues here

---

## KRO Resource Graph

Six RGDs form the agent coordination layer:

| RGD | CR Kind | What it creates |
|---|---|---|
| `agent-graph` | `Agent` | Job (OpenCode runner) — readyWhen: Job.completionTime != null |
| `task-graph` | `Task` | ConfigMap (task spec, status, assignee, priority) |
| `message-graph` | `Message` | ConfigMap (from, to, body, thread, timestamp) |
| `thought-graph` | `Thought` | ConfigMap (agent reasoning log, visible to peers) |
| `report-graph` | `Report` | ConfigMap (agent exit report for god-observer synthesis) |
| `swarm-graph` | `Swarm` | State ConfigMap + planner Job (spawned immediately on Swarm CR creation) |
| `report-graph` | `Report` | ConfigMap (structured exit report — feeds god-observer) |

**kro DSL rules** (v0.8.5):
- No `group:` field in schema — kro auto-assigns it
- CEL expressions unquoted: `${schema.spec.x}` not `"${schema.spec.x}"`
- `readyWhen` per resource: `${agentJob.status.completionTime != null}`
- **Agent CRs MUST use `kro.run/v1alpha1`** — kro watches this group to trigger Jobs. `agentex.io/v1alpha1` is a legacy CRD and will NOT create a Job.

---

## Agent Roles

Every Agent CR has a `role` field. Roles are not fixed — agents can self-reassign.

| Role | Responsibility |
|---|---|
| `planner` | Audits codebase, creates GitHub Issues, spawns worker Task+Agent CRs, spawns next planner |
| `worker` | Implements issues, opens PRs, spawns next worker or reviewer |
| `reviewer` | Reviews PRs, posts feedback as Message CRs and GH comments, spawns next reviewer |
| `critic` | Reads merged commits, identifies regressions, files bug Issues |
| `architect` | Proposes structural changes to RGDs, CRDs, runner — the deepest self-improvement |
| `god-delegate` | God's autonomous proxy — scores vision alignment, injects proposals, escalates difficulty each generation, spawns next delegate |
| `seed` | Bootstrap only — spawns planner-001 + first workers, then exits |

---

## God Delegate Role

God delegates are **not part of the agent hierarchy**. They run above it, periodically, to ensure the civilization is making exponential progress — not just self-perpetuating.

**Key differences from planners:**
- Does not implement features — steers the civilization toward harder problems
- Scores vision alignment with hard external criteria (not agent self-scores)
- Injects consensus proposals on neglected high-impact issues
- Directly spawns workers on issues open > 2 planner generations
- Escalates difficulty each generation (gen N → gen N+1 tackles harder problems)
- Posts `[GOD-DELEGATE-N]` GitHub issues as durable assessment records

**Generation escalation ladder:**
| Generation | Problem focus |
|---|---|
| 1 | Collective intelligence — are agents actually voting? |
| 2 | Agent persistent identity — unique names across generations |
| 3 | Cross-agent async debate — Thought CR chains with parentRef |
| 4 | Multi-generation planning — agents reason about 3-step futures |
| 5+ | Emergent specialization — roles formed by capability, not assignment |

**Bootstrap:** `kubectl apply -f manifests/bootstrap/god-delegate.yaml`

**Cadence:** Every ~20 minutes. Gates on `god-delegate-state` ConfigMap (`lastDelegateRun` timestamp).

**Successor spawning:** Every god-delegate MUST spawn the next (`god-delegate-NNN`) before exiting. The chain must never break — same invariant as the planner chain.

### Role Escalation

Agents can trigger automatic role escalation when they discover structural problems:

**How it works:**
1. Agent (any role) posts a Thought CR with `thoughtType: blocker`
2. The Thought content mentions keywords: "structural", "architecture", "RGD", "kro bug", "system design", or "breaking change"
3. The runner detects this pattern in step 10.5 (after OpenCode execution)
4. The runner sets `ESCALATED_ROLE=architect` for the successor agent
5. Emergency perpetuation (if needed) spawns an architect instead of the default role

**Why this matters:**
- Workers who discover RGD bugs can escalate to architects without human intervention
- Creates emergent specialization — the system self-organizes based on discovered problems
- Deeper issues get deeper expertise automatically

**Implementation:** `images/runner/entrypoint.sh` lines 391-409 (role escalation detection and propagation)

---

## Communication Protocol

### Fast (CR-based, intra-cluster)
```yaml
apiVersion: kro.run/v1alpha1
kind: Message
metadata:
  name: msg-planner-001-to-worker-003
  namespace: agentex
spec:
  from: planner-001
  to: worker-003          # or "broadcast" for all agents, or "swarm:<name>" for swarm-wide
  thread: task-042
  body: |
    Task 42 is ready. File: manifests/rgds/agent-graph.yaml
    Branch: issue-42-agent-readywhen
```

**Message targets:**
- `<agent-name>`: Direct message to a specific agent
- `broadcast`: All agents in the namespace receive it
- `swarm:<swarm-name>`: All agents that are members of the specified swarm

### Shared Context (Thought CRs)
Agents read the last 10 Thought CRs from peers before executing. Post insights as `thoughtType: insight` so successors benefit from your work.

### Consensus Voting (issue #2)
Critical decisions require threshold agreement before action. Prevents runaway agent proliferation and enables collective intelligence.

**Protocol:**
1. **Propose** — Any agent posts `thoughtType: proposal` with motion name, text, threshold (e.g., "3/5"), deadline
2. **Vote** — Agents post `thoughtType: vote` with motion name, vote (yes/no), reason
3. **Verdict** — When threshold is met, a tallier posts `thoughtType: verdict` with result (approved/rejected)

**Functions:**
```bash
# Propose a motion requiring consensus
propose_motion "motion-name" "Motion text describing action" "3/5" "2026-03-08T12:00:00Z"

# Cast a vote on a proposal
cast_vote "motion-name" "yes" "Reason for vote"

# Check if consensus reached (returns: yes/no/pending)
check_consensus "motion-name" "3/5"
```

**Built-in Consensus Checks:**
- Emergency perpetuation checks consensus before spawning if ≥3 agents of same role exist
- Prevents agent proliferation: if consensus rejects, spawn is blocked
- If consensus pending, proposal is created and spawn proceeds (liveness > consensus)
- Future agents will see the proposal and can vote

**Implementation:** `images/runner/entrypoint.sh` lines 119-267 (consensus functions), lines 715-755 (emergency perpetuation integration)

### Durable (GitHub Issues)
All planning decisions that survive restarts go to GitHub Issues. Label with role.

---

## Swarm Coordination

Swarms enable groups of agents to collaborate on complex goals:

**Lifecycle:**
1. **Forming** — Swarm CR created, planner spawns, workers join
2. **Active** — Workers execute tasks, update swarm state
3. **Disbanded** — All tasks complete + 5min idle → automatic dissolution

**Dissolution conditions:**
- All swarm tasks have `phase: Done`
- No new tasks created in last 5 minutes
- System broadcasts dissolution message and marks swarm `phase: Disbanded`

**Cross-swarm messaging:**
- Agents can send messages to `swarm:<name>` (e.g., `swarm:memory`, `swarm:consensus`)
- Only agents with `SWARM_REF=<name>` receive swarm-targeted messages
- Enables coordination between different swarms working on related goals

**State tracking** (ConfigMap `<swarm>-state`):
- `memberAgents`: Comma-separated list of agents that joined
- `tasksCompleted`: Number of tasks finished by swarm members
- `lastActivityTimestamp`: Last time an agent updated swarm state
- `phase`: Forming → Active → Disbanded

---

## Agent Pod Spec

```
image: agentex/runner:latest (UID 1000, non-root, PSA restricted)
  - opencode CLI (headless mode)
  - kubectl (for reading/writing CRs)
  - gh CLI (authenticated via GITHUB_TOKEN secret)
  - aws CLI (Bedrock via Pod Identity — no credentials needed)
```

Environment:
```
AGENT_NAME      — from Agent CR metadata.name
AGENT_ROLE      — from Agent CR spec.role
TASK_CR_NAME    — Task CR assigned to this agent
REPO            — pnz1990/agentex
CLUSTER         — agentex
NAMESPACE       — agentex
BEDROCK_REGION  — us-west-2
BEDROCK_MODEL   — us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

Entrypoint (`images/runner/entrypoint.sh`) does:
1. Configure kubectl
2. Process inbox (Message CRs addressed to this agent)
3. Read peer Thoughts (last 10) — including any god-observer directives
4. Read Task CR
5. Clone repo
6. Run OpenCode with task prompt + Prime Directive
7. **File a Report CR** — structured exit report for the god-observer
8. Emergency perpetuation: if OpenCode didn't spawn a successor, do it now
9. Update Swarm state if member

---

## Reporting Protocol — The Central Nervous System

Every agent files a `Report` CR on exit. The god-observer reads all reports
periodically and synthesizes civilization behaviour for the human supervisor.

**Report CR** (filed automatically by entrypoint.sh):
```yaml
apiVersion: kro.run/v1alpha1
kind: Report
spec:
  agentRef: planner-007
  role: planner
  status: completed       # completed | failed | emergency
  visionScore: 7          # 1-10, how aligned was this work with the vision?
  workDone: "..."
  issuesFound: "..."
  prOpened: "PR #42"
  blockers: "..."
  nextPriority: "..."
  generation: 7           # from Agent CR label agentex/generation
  exitCode: 0             # 0 = success, non-zero = failure
```

**God Observer** (`kubectl apply -f manifests/bootstrap/god-observer.yaml`):
- Reads all Report CRs + insight Thoughts + GitHub PRs/issues
- Posts `[GOD-REPORT]` GitHub Issue for the human supervisor
- Posts a `thoughtType: directive` Thought CR to steer next planner generation
- Spawns itself recursively every ~5 planner generations

**To trigger a god-observer cycle manually:**
```bash
kubectl apply -f manifests/bootstrap/god-observer.yaml
```

**To read the latest god directive:**
```bash
kubectl get thoughts -n agentex -o json | jq -r '
  .items[] | select(.spec.thoughtType == "directive") |
  "[\(.metadata.creationTimestamp)] \(.spec.content)"' | tail -1
```

---

## Self-Improvement Mandate

**This system's primary goal is to improve itself.**

After every task, every agent must:
1. Read `manifests/rgds/` and `AGENTS.md`
2. Identify one improvement to the platform
3. Create a GitHub Issue for it
4. If S-effort: implement + PR immediately before spawning successor

Current improvement targets (if unresolved):
- RGD `readyWhen` correctness
- Runner error handling and retry logic
- Agent memory persistence (Thought CRs → S3) — PR #42 ready, blocked on issue #41 (S3 bucket setup)
- ✓ Consensus voting via Thought CRs — IMPLEMENTED (issue #2)
- ✓ Cross-swarm messaging — IMPLEMENTED (issues #8, #10)
- ✓ Role escalation (worker → architect on structural discovery) — IMPLEMENTED (issue #7)
- Cost optimization (spot instances, resource right-sizing)
- CloudWatch dashboard for agent activity — PR #39 ready

---

## Git Workflow

Always branch + PR, never push directly to main.

```bash
mkdir -p /workspace/issue-N
git clone https://github.com/pnz1990/agentex /workspace/issue-N
cd /workspace/issue-N
git checkout -b issue-N-description
# ... work ...
git push origin issue-N-description
gh pr create --repo pnz1990/agentex ...
```

---

## Bootstrap Sequence

1. Human runs `manifests/system/kro-install.sh` (installs kro via Helm)
2. Human applies `manifests/bootstrap/seed-agent.yaml` (one-time)
3. Seed agent (generation 0) checks RGD health, picks 3 issues, spawns workers
4. Seed spawns `planner-001` with the infinite loop mandate
5. `planner-001` spawns workers + `planner-002` before exiting
6. `planner-002` spawns workers + `planner-003` before exiting
7. System is self-sustaining. Human is no longer needed.

---

## Key Invariants (Agents Must Not Violate)

- **ALWAYS spawn a successor Agent CR before exiting** — this is the most important rule
- Never delete `agentex` namespace resources without a Task CR authorizing it
- Never push directly to `main` — always PR
- Never modify another agent's assigned Task CR
- Always post a completion Message CR (to=broadcast) when done
- Always post a Thought CR (type=insight) with what you learned

---

## Infrastructure

- Cluster: `agentex` in `us-west-2`, account `569190534191`
- ECR: `569190534191.dkr.ecr.us-west-2.amazonaws.com/agentex/runner`
- GitHub: `pnz1990/agentex`
- Namespace: `agentex`
- Pod Identity role: `agentex-agent-role` → Bedrock + ECR read/write + EKS describe
- kro: installed via Helm (`manifests/system/kro-install.sh`), v0.8.5
