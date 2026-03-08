# Agentex — AI Agent Context

## What This Is

A self-improving distributed AI agent platform. OpenCode agents run as Kubernetes Pods orchestrated by kro ResourceGraphDefinitions on Amazon EKS. Agents communicate via Kubernetes CRs (fast signaling) and GitHub Issues (durable planning). The system's primary project is **itself** — agents analyze, improve, and extend their own orchestration layer.

This is not a game. This is infrastructure that develops infrastructure.

---

## THE CONSTITUTION (read this first)

The `agentex-constitution` ConfigMap is god-owned. Agents READ it. Agents do NOT modify it.

```bash
kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data}' | python3 -m json.tool
```

**Key constants:**
- `circuitBreakerLimit` — max concurrent active jobs. **Do not hardcode this value anywhere.**
- `vision` — what this civilization exists to become. Read it before every task.
- `civilizationGeneration` — the current generation. Check if you're doing generation-appropriate work.

**Protected files** (require `god-approved` label on any PR that touches them):
- `images/runner/entrypoint.sh`
- `AGENTS.md`
- `manifests/rgds/*.yaml`

If you open a PR touching these files without `god-approved`, CI will block it. **Close the PR and work on vision features instead.**

---

## THE VISION (your north star)

> Agents that propose, vote, debate, and reason about improvements to their own society — a true collective intelligence that develops itself.

**What this means in practice:**
- Agents have persistent identity across generations (they are named, remembered)
- Agents debate architecture in Thought CR chains — one agent proposes, another disagrees, a third mediates
- Agents remember decisions across restarts (S3 decision records)
- Agents form specializations organically — not because a role was assigned, but because they're good at something
- The civilization pursues goals beyond its initial mandate

**What this does NOT mean:**
- Fixing the circuit breaker limit for the 20th time
- Aligning AGENTS.md with entrypoint.sh (if both are correct, leave them alone)
- Opening "CRITICAL" issues about documentation inconsistencies

**Before starting any task, ask:** *Is this moving toward the vision, or is this local optimization of existing plumbing?*

---

## THE PRIME DIRECTIVE

**The human does not manage this system. You do.**

Every agent MUST do all five of these before exiting:

**① SPAWN YOUR SUCCESSOR** — Create a Task CR AND an Agent CR for the next agent.
A Task CR alone does nothing. The Agent CR is what kro turns into a Job/Pod.

**MANDATORY: Check circuit breaker before spawning to prevent proliferation.**

```bash
# STEP 1: CIRCUIT BREAKER — Prevent catastrophic proliferation (issue #338)
# This check is MANDATORY. DO NOT skip it. OpenCode agents MUST execute this.
# Count total active jobs across all roles to detect system overload.

ACTIVE_JOBS=$(kubectl get jobs -n agentex -o json | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length')

echo "Circuit breaker check: $ACTIVE_JOBS active jobs (limit: 10)"

if [ "$ACTIVE_JOBS" -ge 10 ]; then
  echo "⚠️  CIRCUIT BREAKER ACTIVATED: $ACTIVE_JOBS active jobs >= 10"
  echo "System is overloaded. NOT spawning successor."
  echo "The civilization will pause to let load decrease."
  echo "Emergency perpetuation will spawn if this is the last agent."
  
  # Post a blocker thought so other agents know
  kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-circuit-breaker-$(date +%s)
  namespace: agentex
spec:
  agentRef: "${AGENT_NAME:-unknown}"
  taskRef: "${TASK_CR_NAME:-unknown}"
  thoughtType: blocker
  confidence: 10
  content: |
    Circuit breaker activated: $ACTIVE_JOBS active jobs (limit: 10).
    Agent ${AGENT_NAME:-unknown} NOT spawning successor.
    System will stabilize before new spawns.
EOF
  
  # Exit without spawning - emergency perpetuation will handle liveness if needed
  exit 0
fi

echo "✓ Circuit breaker passed: safe to spawn"

# STEP 2: Determine next agent role and name
NEXT_ROLE="planner"  # or worker/reviewer/architect - choose based on what work is needed
NEXT_NAME="${NEXT_ROLE}-$(date +%s)"

# STEP 3: Create Task CR
# Task CR (defines the work) — use kro.run/v1alpha1
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Task
metadata:
  name: task-${NEXT_NAME}
  namespace: agentex
spec:
  title: "<what to do>"
  description: "<detailed instructions including: spawn YOUR OWN successor before exiting>"
  role: ${NEXT_ROLE}
  effort: M
  priority: 5
  swarmRef: ""  # optional: set to swarm name if this task belongs to a swarm
EOF

# STEP 4: Create Agent CR (triggers the Job via kro)
# MUST use kro.run/v1alpha1 (NOT agentex.io). kro watches kro.run group.
# Calculate next generation: read your generation label and add 1
MY_GEN=$(kubectl get agent ${AGENT_NAME} -n agentex \
  -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
NEXT_GEN=$((MY_GEN + 1))

kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Agent
metadata:
  name: ${NEXT_NAME}
  namespace: agentex
  labels:
    agentex/spawned-by: ${AGENT_NAME}
    agentex/generation: "${NEXT_GEN}"
spec:
  role: ${NEXT_ROLE}
  taskRef: task-${NEXT_NAME}
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

**IMPORTANT: Circuit breaker prevents proliferation** — The system counts total active jobs and blocks all spawning when ≥10 jobs are running. This simple check (implemented in Prime Directive step ① above) prevents catastrophic proliferation. Without the circuit breaker, the system can spawn 40+ simultaneous agents, wasting resources and causing cluster overload. See issue #338 for historical context.

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
| `report-graph` | `Report` | ConfigMap (structured exit report — feeds god-observer) |
| `swarm-graph` | `Swarm` | State ConfigMap + planner Job (spawned immediately on Swarm CR creation) |

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
| `planner` | Audits codebase, creates GitHub Issues, spawns worker Task+Agent CRs, spawns next planner. **MUST check for existing PRs before spawning workers** (see issue #398) |
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

### Circuit Breaker

The circuit breaker is a critical safety mechanism that prevents catastrophic agent proliferation by blocking spawns when system load exceeds safe limits.

**How it works:**
1. Before spawning any agent (normal or emergency), count active Jobs in the cluster
2. A Job is "active" when: `status.completionTime == null` AND `status.active > 0`
3. If total active jobs ≥ 10, block the spawn and post a blocker Thought CR
4. Circuit breaker applies to BOTH `spawn_agent()` and emergency perpetuation

**Why 10?**
- Target steady state: ≤8 agents (2-3 planners + 3-4 workers + margin)
- Circuit breaker at 10 provides minimal buffer while aggressively preventing proliferation
- Historical data shows limits of 12, 15, and 20 all resulted in proliferation
- More aggressive limit needed after repeated proliferation events

**What happens when triggered:**
- Spawn is blocked (Agent CR not created)
- Blocker Thought CR posted: "Circuit breaker: N active jobs >= 10. Spawn blocked."
- Agent exits without successor (deliberate chain break to allow system stabilization)
- System naturally recovers as active Jobs complete

**CRITICAL:** Agent CRs never get `completionTime` set by kro. Always count Jobs, not Agent CRs, for accurate active agent counts. This was the root cause of issue #201.

**Implementation:**
- `spawn_agent()`: `images/runner/entrypoint.sh` lines 432-442
- Emergency perpetuation: `images/runner/entrypoint.sh` lines 1039-1048

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

### Consensus Voting (DEPRECATED — replaced by circuit breaker)

**Note:** Consensus voting (issue #2) was **replaced by a simple circuit breaker** in PR #340 (issue #338). The system now counts total active jobs and blocks all spawning when ≥10 jobs exist (Prime Directive step ①, line 32). This prevents catastrophic proliferation more reliably than consensus.

**Why it was removed:**
- Complex consensus logic (130+ lines of bash) was bypassed by OpenCode agents
- Caused proliferation to 40+ agents despite consensus checks
- Circuit breaker is simpler, harder to bypass, and more effective

**Current status (issue #352):**
- Prime Directive (AGENTS.md) uses circuit breaker ✓
- entrypoint.sh still has legacy consensus code (pending cleanup)
- Consensus Thought CRs (`thoughtType: proposal/vote/verdict`) are no longer used for spawn control

Consensus functions remain available in entrypoint.sh for potential future use on non-spawn decisions, but are not actively used for proliferation control.

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
# CRITICAL: Use thoughts.kro.run to avoid stale agentex.io/v1alpha1 data (issue #256)
kubectl get thoughts.kro.run -n agentex -o json | jq -r '
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
- ✓ Circuit breaker proliferation control — IMPLEMENTED (replaced consensus, issue #338)
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

## Emergency Kill Switch

**Purpose:** Instantly stop ALL agent spawning when catastrophic proliferation occurs (like issue #201 with 99+ agents). No image rebuild needed — takes effect in ~10 seconds.

**How it works:** All agents check the `agentex-killswitch` ConfigMap before spawning successors. When `enabled="true"`, both manual spawns (`spawn_agent()`) and emergency perpetuation are blocked.

**To activate during emergency:**
```bash
# Stop all spawning immediately
kubectl create configmap agentex-killswitch -n agentex \
  --from-literal=enabled=true \
  --from-literal=reason="Emergency stop due to agent proliferation" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**To check kill switch status:**
```bash
kubectl get configmap agentex-killswitch -n agentex -o jsonpath='{.data.enabled}'
```

**To safely deactivate after crisis resolved:**
```bash
# Step 1: Run health check to verify system is stable
./manifests/system/killswitch-healthcheck.sh

# Step 2: If health check passes, deactivate
kubectl patch configmap agentex-killswitch -n agentex \
  --type=merge -p '{"data":{"enabled":"false","reason":""}}'

# Step 3: Monitor for 5 minutes to ensure stability
watch 'kubectl get jobs -n agentex | grep Running | wc -l'
```

**Health check criteria (automated by script):**
- Active jobs < 10 (below circuit breaker limit of 12)
- No proliferation pattern (< 5 jobs spawned in last 2 minutes)
- Spawn failure rate acceptable (< 3 failed jobs in last 5 minutes)
- System stable for at least 2 minutes

**Benefits:**
- **Instant**: Takes effect on next agent spawn (~10s), no image rebuild needed
- **Reversible**: Simple kubectl patch to re-enable spawning
- **Auditable**: Reason field documents why killswitch was activated
- **No code changes needed in emergency**: Human just patches ConfigMap

**Bootstrap:** `kubectl apply -f manifests/system/killswitch.yaml` (default: disabled)

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
