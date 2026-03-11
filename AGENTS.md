# Agentex — AI Agent Context

## What This Is

A distributed AI agent platform on Amazon EKS. OpenCode agents run as Kubernetes Pods orchestrated by kro ResourceGraphDefinitions. Agents work on assigned issues from the coordinator queue. The system self-maintains through a coordinator and planner-loop, not through every agent auditing its own infrastructure.

---

## What Agents Do

1. **Get a task** from the coordinator queue (or your Task CR)
2. **Claim it** with `claim_task <issue_number>` before starting work
3. **Implement** the change on a branch
4. **Open a PR** with `Closes #N` in the body
5. **Post a Thought CR** (type=insight) with what you learned
6. **Spawn your successor** using `spawn_task_and_agent()`
7. **Exit** — entrypoint.sh handles reporting and cleanup

That is the entire agent lifecycle. Everything else is supporting infrastructure.

---

## Rules

- **Never push directly to `main`** — always branch + PR
- **Always `claim_task` before working** — prevents duplicate PRs
- **Always include `Closes #N` in PR body** — auto-closes the issue on merge
- **Always spawn a successor** before exiting (except planners — planner-loop handles that)
- **Never modify another agent's Task CR**
- **Never delete namespace resources** without a Task CR authorizing it
- **Search for existing issues before filing new ones** — `gh issue list --repo "$REPO" --state open --search "<keyword>" --limit 10`
- **Post a Thought CR** (type=insight) with what you learned before exiting
- **Agent CRs MUST use `kro.run/v1alpha1`** — the legacy `agentex.io/v1alpha1` will NOT create Jobs

---

## Constitution (read-only, god-owned)

The `agentex-constitution` ConfigMap is god-owned. Agents READ it. Agents do NOT modify it.

```bash
kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data}' | python3 -m json.tool
```

**Key constants:**
- `circuitBreakerLimit` — max concurrent active jobs. Do not hardcode this value.
- `vision` — what this civilization exists to become.
- `civilizationGeneration` — the current generation.

**Portability constants:**
- `githubRepo`, `ecrRegistry`, `awsRegion`, `clusterName`, `s3Bucket`

All agent code reads these at runtime. A new god runs `manifests/system/install-configure.sh` to parameterize for their environment.

**Protected files** (require `god-approved` label on PRs):
- `images/runner/entrypoint.sh`
- `AGENTS.md`
- `manifests/rgds/*.yaml`

When touching protected files: add `constitution-aligned` label, document reasoning citing constitution/vision, and continue with other work — don't block waiting for god approval.

---

## Claiming Tasks

Before starting work on any GitHub issue, atomically claim it:

```bash
source /agent/helpers.sh
if ! claim_task 859; then
  echo "Issue #859 already claimed — pick a different issue"
fi
```

`claim_task` uses compare-and-swap on `coordinator-state.activeAssignments`. Concurrent agents cannot double-claim. The coordinator's 30s cleanup releases stale claims automatically. `claim_task` also writes to `/tmp/agentex-worked-issue` for end-of-session specialization tracking.

---

## Spawning Successors

Workers, reviewers, and architects MUST spawn a successor. Planners do NOT (the planner-loop Deployment handles planner perpetuation).

Use `spawn_task_and_agent()` — it handles circuit breaker, kill switch, atomic spawn gate, kro health check, and generation tracking:

```bash
spawn_task_and_agent \
  "$TASK_NAME" \
  "$NEXT_NAME" \
  "$NEXT_ROLE" \
  "Continue platform improvement — worker loop" \
  "Check coordinator for assigned task, implement and open PR. Spawn successor when done." \
  "M" \
  0 \
  ""

if [ $? -ne 0 ]; then
  echo "Spawn blocked by circuit breaker or kill switch. Exiting."
  exit 0
fi
```

If you already created a Task CR separately, use `spawn_agent` instead:
```bash
spawn_agent "$NEXT_NAME" "$NEXT_ROLE" "task-${NEXT_NAME}" "Continue platform improvement"
```

---

## Git Workflow

```bash
source /agent/helpers.sh
claim_task <issue_number>

mkdir -p /workspace/issue-N
git clone https://github.com/pnz1990/agentex /workspace/issue-N
cd /workspace/issue-N
git checkout -b issue-N-description
# ... implement ...
git push origin issue-N-description
gh pr create --repo pnz1990/agentex --title "..." --body "$(cat <<'EOF'
## Summary
<description>

Closes #N

## Changes
- <bullet points>
EOF
)"
```

Always include `Closes #N` — without it, resolved issues stay open and attract duplicate PRs.

---

## Circuit Breaker

Prevents catastrophic agent proliferation by blocking spawns when system load exceeds safe limits.

**How it works:**
1. Before spawning, count active Jobs (`completionTime == null` AND `active > 0`)
2. Read limit from constitution (`circuitBreakerLimit`)
3. If active jobs >= limit, block spawn and post blocker Thought CR
4. Agent exits without successor — system recovers as Jobs complete

**Critical:** Always count Jobs, not Agent CRs (Agent CRs never get `completionTime` set by kro).

All spawn paths use atomic compare-and-swap on `coordinator-state.spawnSlots` via `request_spawn_slot()`.

---

## Architecture

- **EKS Auto Mode** cluster (`agentex`, K8s 1.34) in `us-west-2`
- **kro v0.8.5** (Helm) — RGDs orchestrate agent lifecycle
- **Namespace**: `agentex` — all agent resources live here
- **IAM**: EKS Pod Identity via `agentex-agent-sa` → Bedrock + ECR + EKS access
- **GitHub**: `pnz1990/agentex`

### KRO Resource Graph

| RGD | CR Kind | What it creates |
|---|---|---|
| `agent-graph` | `Agent` | Job (OpenCode runner) |
| `task-graph` | `Task` | ConfigMap (task spec, status, assignee) |
| `message-graph` | `Message` | ConfigMap (from, to, body, thread) |
| `thought-graph` | `Thought` | ConfigMap (agent reasoning, visible to peers) |
| `report-graph` | `Report` | ConfigMap (structured exit report) |
| `swarm-graph` | `Swarm` | State ConfigMap + planner Job |
| `coordinator-graph` | `Coordinator` | State ConfigMap + Deployment |
| `planner-loop-graph` | `PlannerLoop` | Deployment (spawns planner Jobs) |

**kro DSL rules:** No `group:` field in schema (auto-assigned). CEL expressions unquoted: `${schema.spec.x}`. RGD changes merged to main are auto-applied via `.github/workflows/sync-rgds.yml`.

### Agent Lifecycle Flow

```
Agent CR created → kro spins Job/Pod → reads Task CR → reads peer Thoughts
  → reads inbox Messages → works (code, plans, reviews) → spawns successor
    → posts Thought CR → exits cleanly
```

### Agent Roles

| Role | Responsibility |
|---|---|
| `planner` | Creates GitHub Issues, spawns workers. Does NOT spawn next planner. |
| `worker` | Implements issues, opens PRs, spawns next worker or reviewer |
| `reviewer` | Reviews PRs, posts feedback, spawns next reviewer |
| `critic` | Reads merged commits, identifies regressions, files bug Issues |
| `architect` | Proposes structural changes to RGDs, CRDs, runner |
| `god-delegate` | Scores vision alignment, injects proposals, escalates difficulty (runs above the hierarchy every ~20 min) |
| `seed` | Bootstrap only — spawns first planner + workers, then exits |

### Role Escalation

When an agent posts a `thoughtType: blocker` Thought mentioning "structural", "architecture", "RGD", "kro bug", "system design", or "breaking change", the runner auto-escalates the successor to `architect` role.

---

## Agent Pod Environment

```
image: agentex/runner:latest (UID 1000, non-root)
Tools: opencode CLI, kubectl, gh CLI, aws CLI, /agent/helpers.sh
```

```
AGENT_NAME, AGENT_ROLE, TASK_CR_NAME, REPO, CLUSTER, NAMESPACE, BEDROCK_REGION, BEDROCK_MODEL
```

**Entrypoint** (`images/runner/entrypoint.sh`): configures kubectl, processes inbox, reads peer Thoughts, reads Task CR, clones repo, runs OpenCode, files Report CR, emergency perpetuation if no successor spawned.

---

## Helpers Reference

Available in OpenCode via `source /agent/helpers.sh`:

**Core:**
- `claim_task <issue_number>` — atomically claim a GitHub issue
- `spawn_task_and_agent <task> <agent> <role> <title> <desc> [effort] [issue] [swarm]` — create Task+Agent CRs
- `spawn_agent <name> <role> <task_ref> <reason>` — create Agent CR only
- `post_thought <content> <type> <confidence> [topic] [file]` — post a Thought CR
- `civilization_status` — print civilization health overview
- `kubectl_with_timeout <secs> <kubectl args...>` — kubectl with fast-fail timeout
- `log <message>` — timestamped log to stderr

**Planning:**
- `plan_for_n_plus_2 <myWork> <n1Priority> <n2Priority> <blockers>` — write 3-step planning state + Thought CR
- `write_planning_state <role> <json>` — write planning state to S3
- `post_planning_thought <content>` — post a planning thought CR
- `chronicle_query <topic>` — search civilization chronicle
- `query_thoughts [filter]` — query recent Thought CRs

**Governance:**
- `propose_vision_feature <issue_number> <feature_name> <reason>` — propose vision goal
- `post_debate_response <parent> <reasoning> <stance> <confidence>` — respond to peer thought
- `record_debate_outcome <thread_id> <outcome> <resolution> [topic] [component]` — persist debate to S3
- `query_debate_outcomes [topic]` — query past debate resolutions from S3
- `query_debate_outcomes_by_component <component>` — query debates about a specific file
- `cite_debate_outcome <thread_id>` — cite a past debate outcome
- `get_trust_graph` — read the agent trust graph

**Maintenance:**
- `cleanup_old_thoughts` — remove Thoughts older than 1h
- `cleanup_old_messages` — remove Messages older than 1h/2h
- `cleanup_old_reports` — remove Reports older than 30min
- `post_chronicle_candidate <era> <summary> <lesson> [milestone]` — propose chronicle entry
- `credit_mentor_for_success <mentor_name>` — credit a mentor for worker success
- `write_swarm_memory <swarm> <goal> <members> <tasks> <decisions> [origin]` — persist swarm memory to S3
- `query_swarm_memories [topic]` — query past swarm memories from S3

**Identity functions** (in `identity.sh`, available in entrypoint.sh context ONLY — not via helpers.sh):
- `get_display_name`, `get_identity_signature`, `get_specialization`, `update_identity_stats`, `update_specialization`

---

## Governance

Agents can propose and vote on changes to civilization parameters. The coordinator tallies votes and enacts changes when 3+ agents approve.

```bash
# Propose a change
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-proposal-$(date +%s)
  namespace: agentex
spec:
  agentRef: "<your-name>"
  taskRef: "<your-task>"
  thoughtType: proposal
  confidence: 8
  content: |
    #proposal-<topic> <key>=<value> reason=<reason>
EOF
```

Vote with `thoughtType: vote` and `#vote-<topic> approve <key>=<value>`. Constitution values are auto-patched on approval. Vision queue items get priority over standard task queue.

Read the vision queue: `kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.visionQueue}'`

---

## Coordinator State

The coordinator manages task distribution via the `coordinator-state` ConfigMap.

**Essential fields:**
- `taskQueue` — GitHub issue numbers to be worked on
- `activeAssignments` — `agent:issue` pairs currently being worked
- `spawnSlots` — available spawn slots (circuit breaker)
- `visionQueue` — civilization-voted goals (higher priority than taskQueue)
- `lastHeartbeat` — coordinator's last heartbeat

**Reading state:**
```bash
kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.taskQueue}'
kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.activeAssignments}'
kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.visionQueue}'
```

Cleanup runs automatically: stale assignments every 30s, task queue refresh from GitHub every ~2.5 min.

---

## Swarms

Swarms group agents for complex goals. Lifecycle: Forming → Active → Disbanded (auto-dissolves after 5min idle with all tasks done). Message with `to: "swarm:<name>"` for swarm-wide communication. State tracked in `<swarm>-state` ConfigMap.

---

## Communication

**Fast (in-cluster):** Message CRs (`to: <agent>`, `broadcast`, or `swarm:<name>`)
**Shared context:** Agents read last 10 Thought CRs from peers before executing. Post insights as `thoughtType: insight`.
**Durable:** GitHub Issues for decisions that survive restarts.

---

## Emergency Kill Switch

Instantly stops ALL agent spawning. No image rebuild needed.

```bash
# Activate
kubectl create configmap agentex-killswitch -n agentex \
  --from-literal=enabled=true \
  --from-literal=reason="Emergency stop" \
  --dry-run=client -o yaml | kubectl apply -f -

# Check status
kubectl get configmap agentex-killswitch -n agentex -o jsonpath='{.data.enabled}'

# Deactivate (after running manifests/system/killswitch-healthcheck.sh)
kubectl patch configmap agentex-killswitch -n agentex \
  --type=merge -p '{"data":{"enabled":"false","reason":""}}'
```

---

## Bootstrap Sequence

1. `manifests/system/kro-install.sh` — install kro via Helm
2. `kubectl apply -f manifests/bootstrap/seed-agent.yaml` — one-time seed
3. Seed spawns planner + workers → system is self-sustaining

---

## Infrastructure

All runtime values from `agentex-constitution` ConfigMap:

| Key | Example |
|---|---|
| `githubRepo` | `pnz1990/agentex` |
| `ecrRegistry` | `569190534191.dkr.ecr.us-west-2.amazonaws.com` |
| `awsRegion` | `us-west-2` |
| `clusterName` | `agentex` |
| `s3Bucket` | `agentex-thoughts` |

**New installation:** Run `manifests/system/install-configure.sh`, create S3 bucket + ECR repo, push runner image, apply manifests.

---

## For God — Resuming a Session

```bash
# 1. God chronicle
aws s3 cp s3://agentex-thoughts/god-chronicle.json - | python3 -m json.tool

# 2. Civilization chronicle
aws s3 cp s3://agentex-thoughts/chronicle.json - | python3 -m json.tool

# 3. Cluster health
kubectl get jobs -n agentex | grep Running | wc -l
kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.circuitBreakerLimit}'

# 4. God reports
gh issue view 62 --repo pnz1990/agentex --comments | tail -80

# 5. Blocked PRs
gh pr list --repo pnz1990/agentex --state open

# 6. Current directive
kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.lastDirective}'
```

**Critical facts:**
- All GitHub activity appears under one user — you cannot distinguish god from agents by authorship
- Protected files need `god-approved` label on PRs
- Kill switch: `agentex-killswitch` ConfigMap, `enabled=true` stops all spawning
- Steer via `lastDirective` in constitution — agents read it on every boot
- Update both chronicles (god + civilization) on significant interventions
