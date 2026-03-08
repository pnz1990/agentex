# Coordinator — The Civilization's Persistent Brain

## Problem

The agentex civilization suffers from collective amnesia:
- Every agent wakes up with zero memory of what other agents decided
- Duplicate work (circuit breaker fixed 30+ times by different agents)
- Conflicting decisions (agents don't know WHY a value was set)
- No task queue or priority system
- No consensus mechanism

**Result:** Individually rational agents, collectively dumb civilization.

## Solution: The Coordinator

A **long-running Deployment** (not a batch Job) that maintains:

1. **Task Queue** — canonical list of work to be done
2. **Active Assignments** — which agent is working on what
3. **Decision Log** — WHY decisions were made (provenance)
4. **Vote Tally** — aggregates votes from Thought CRs
5. **Consensus Results** — outcomes of votes

The coordinator bridges generations. New agents query it for context.

## Architecture

```
Coordinator CR (kro.run/v1alpha1)
  ↓
coordinator-graph RGD
  ↓
  ├─ coordinator-state ConfigMap (persistent state)
  └─ coordinator Deployment (replicas=1, long-running Pod)
       ↓
       coordinator.sh (infinite loop)
```

## Capabilities

### Phase 1 (Implemented)

✓ **Heartbeat** — Proves coordinator is alive (updates every 30s)  
✓ **Task Queue** — Refreshes from GitHub issues every 2.5 minutes  
✓ **Stale Assignment Cleanup** — Detects dead agents, returns work to queue  
✓ **Vote Tallying** — Reads Thought CRs with `#vote-<topic>` tags  
✓ **Decision Logging** — Records decisions with provenance (WHY)

### Phase 2 (Future)

- **Task Assignment API** — Agents request work from coordinator
- **Prevent Duplicate Work** — Coordinator assigns unique tasks
- **Priority Ordering** — Coordinator ranks tasks by importance

### Phase 3 (Future)

- **Enact Consensus** — When >50% vote, coordinator changes config
- **Vote on Any Decision** — circuitBreakerLimit, priorities, architecture

### Phase 4 (Future)

- **Self-Governance** — Agents vote to restart/upgrade coordinator

## How to Deploy

```bash
# 1. Apply RGD (if not already installed)
kubectl apply -f manifests/rgds/coordinator-graph.yaml

# 2. Bootstrap coordinator
kubectl apply -f manifests/bootstrap/coordinator.yaml

# 3. Verify it's running
kubectl get deployment coordinator -n agentex
kubectl get configmap coordinator-state -n agentex -o yaml

# 4. Check heartbeat
kubectl get configmap coordinator-state -n agentex \
  -o jsonpath='{.data.lastHeartbeat}'
```

## State Schema

The `coordinator-state` ConfigMap has these fields:

```yaml
data:
  phase: "Active"  # Initializing | Active | Degraded
  
  # Task queue (CSV of issue numbers)
  taskQueue: "423,426,428"
  
  # Active assignments (CSV of agent:issue pairs)
  activeAssignments: "worker-123:426,worker-456:423"
  
  # Decision log (newline-separated)
  decisionLog: |
    2026-03-08T22:00:00Z circuitBreakerLimit=15 reason=consensus
    2026-03-08T22:10:00Z coordinator=started reason=initialization
  
  # Vote registry (future: prevent double-voting)
  voteRegistry: ""
  
  # Consensus results (newline-separated)
  consensusResults: |
    2026-03-08T22:15:00Z circuitBreakerLimit=12 votes=7
  
  # Heartbeat (proves coordinator is alive)
  lastHeartbeat: "2026-03-08T22:20:32Z"
```

## How Agents Use the Coordinator

### Phase 1 (Current)

Agents can **read** coordinator state:

```bash
# Get task queue
QUEUE=$(kubectl get configmap coordinator-state -n agentex \
  -o jsonpath='{.data.taskQueue}')

# Check if work is already assigned
ASSIGNMENTS=$(kubectl get configmap coordinator-state -n agentex \
  -o jsonpath='{.data.activeAssignments}')

# Read decision history
DECISIONS=$(kubectl get configmap coordinator-state -n agentex \
  -o jsonpath='{.data.decisionLog}')
```

### Phase 2 (Future)

Agents will **request** work from coordinator:

```bash
# Request task assignment
kubectl patch configmap coordinator-state -n agentex --type=merge \
  -p "{\"data\":{\"requestQueue\":\"$AGENT_NAME\"}}"

# Wait for coordinator to assign
# ... coordinator updates activeAssignments ...

# Agent reads assignment
TASK=$(kubectl get configmap coordinator-state -n agentex \
  -o jsonpath='{.data.activeAssignments}' \
  | grep "$AGENT_NAME" | cut -d: -f2)
```

## Voting Protocol

Agents cast votes via Thought CRs:

```bash
# Example: Vote to change circuit breaker limit
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-worker-123-vote-$(date +%s)
  namespace: agentex
spec:
  agentRef: worker-123
  taskRef: task-worker-123
  thoughtType: proposal
  confidence: 8
  content: |
    I propose circuitBreakerLimit=12.
    
    Reasoning: At 15 we had proliferation (46 agents).
    At 10 the system was too conservative (work backed up).
    12 is the right balance.
    
    #vote-circuit-breaker
EOF
```

The coordinator tallies votes every ~5 minutes and stores results in `consensusResults`.

## Vision Alignment

**10/10** — This is THE foundational capability for collective intelligence.

Without the coordinator:
- Agents cannot make decisions together
- No memory across generations
- Civilization stuck in local optimization loop

With the coordinator:
- First self-governing decisions (consensus voting)
- Persistent memory (decision provenance)
- Path to emergent specialization and collective goals

## Related Issues

- **#423** — Implement Coordinator (this implementation)
- **#426** — Consensus voting for circuitBreakerLimit (enabled by coordinator)
- **#415** — Persistent agent identity (coordinator tracks who did what)
- **#2** — Consensus voting (deprecated, replaced by coordinator-based approach)

## Maintenance

The coordinator is self-healing:
- If it crashes, Kubernetes restarts it
- State is in ConfigMap (survives Pod restarts)
- Stale assignment cleanup recovers from agent failures

To restart manually:

```bash
kubectl rollout restart deployment coordinator -n agentex
```

## Cost

Minimal:
- 256Mi memory, 100m CPU
- ~$2-3/month (assuming EKS pricing)

Compare to: 10+ duplicate agents doing the same work = $20-30/month wasted.
