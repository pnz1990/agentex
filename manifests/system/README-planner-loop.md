# Planner Loop — Thin Perpetuation Heartbeat

**Issue:** #867  
**Status:** Implemented  
**Version:** agentex v2.0 (Generation 3)

## What This Is

A **thin Deployment** that acts as the planner chain's perpetuation heartbeat. The Deployment continuously spawns planner Jobs (mortal agents with generational identity) but does not do planning itself.

## Problem It Solves

The previous planner chain model (each planner spawns its successor) was fragile:

- **Chain breaks were common** — emergency perpetuation existed solely to patch this
- **TOCTOU race (issue #828)** — two agents completing simultaneously both trigger emergency perp → duplicate planners
- **Reactive watchdog** — coordinator's `ensure_planner_chain_alive()` was reactive, not preventive
- **Complex entrypoint.sh logic** — exists largely to defend against chain breaks

## Architecture

```
planner-loop Deployment (replicas: 1, thin bash loop, no OpenCode)
  └── every 60s:
       1. Check circuit breaker (read constitution circuitBreakerLimit)
       2. Check kill switch (agentex-killswitch)
       3. Count active planner Jobs
       4. If no planner active + slots available: spawn planner-gen{N}-{timestamp} Job
       5. Wait and repeat
```

**The Deployment is the perpetuation mechanism. The Job is the agent with identity, LLM session, generational memory.**

## What This Solves

- ✅ **Exactly-one-planner** guaranteed by Kubernetes (`replicas: 1`) — no TOCTOU
- ✅ **No chain to break** — Deployment is immortal, Kubernetes keeps it alive
- ✅ **Zero-downtime generation transitions** — god patches constitution `civilizationGeneration` → loop spawns next-gen planner
- ✅ **Eliminates planner emergency perpetuation** — coordinator `ensure_planner_chain_alive()` becomes unnecessary
- ✅ **Planners stop spawning successors** — simpler entrypoint.sh, one fewer Prime Directive step
- ✅ **Generational identity preserved** — planner Jobs still get `agentex/generation` label, persistent identity names, N+2 planning state

## What Stays the Same

- ✅ Planner Jobs: still mortal, still run OpenCode, still have generational identity
- ✅ Circuit breaker: still enforced (loop checks before spawning)
- ✅ Workers: unchanged — still spawn their own successors
- ✅ God interface: advancing generation = patch constitution ConfigMap `civilizationGeneration` field

## Analogy

The **coordinator** is already this model. It's a Deployment that manages work distribution. The **planner-loop** is a simpler version: just spawn the next planner Job when the current one finishes.

## Files Changed

### New Files
- `images/runner/planner-loop.sh` — bash loop script that spawns planner Jobs
- `manifests/rgds/planner-loop-graph.yaml` — kro RGD (PlannerLoop CR → Deployment)
- `manifests/bootstrap/planner-loop.yaml` — bootstrap manifest to deploy the loop
- `manifests/system/README-planner-loop.md` — this file

### Modified Files
- `images/runner/Dockerfile` — added planner-loop.sh to image
- `AGENTS.md` — updated Prime Directive (planners do NOT spawn successors)
- `AGENTS.md` — updated Core Concept diagram to show planner-loop
- `AGENTS.md` — updated RGD table (7 → 8 RGDs)
- `AGENTS.md` — updated Agent Roles table (planner no longer spawns successor)

## Deployment

```bash
# Step 1: Apply the RGD
kubectl apply -f manifests/rgds/planner-loop-graph.yaml

# Step 2: Deploy the planner-loop
kubectl apply -f manifests/bootstrap/planner-loop.yaml

# Step 3: Verify deployment
kubectl get deployment planner-loop -n agentex
kubectl logs -n agentex -l app=agentex-planner-loop --tail=50

# Step 4: Monitor planner spawns
kubectl get jobs -n agentex -l agentex/role=planner -w
```

## Coordinator Simplification (Future Work)

With planner-loop in place, the coordinator's `ensure_planner_chain_alive()` function can be:
- **Option A:** Removed entirely (planner-loop is now the primary mechanism)
- **Option B:** Kept as a redundant safety mechanism (defense in depth)

Recommendation: Keep it as defense in depth initially, remove after 10+ planner generations with zero chain breaks.

## Configuration

Planner-loop reads these values from the constitution ConfigMap:
- `circuitBreakerLimit` — max concurrent active jobs (enforced before spawn)
- `civilizationGeneration` — used for planner naming (planner-gen{N}-{timestamp})

Planner-loop reads this value from its own ConfigMap:
- `loopInterval` — seconds between checks (default: 60s)

## Kill Switch Integration

The planner-loop respects the kill switch:
```bash
# Emergency stop all spawning
kubectl patch configmap agentex-killswitch -n agentex \
  --type=merge -p '{"data":{"enabled":"true"}}'

# Planner-loop will skip spawns until:
kubectl patch configmap agentex-killswitch -n agentex \
  --type=merge -p '{"data":{"enabled":"false"}}'
```

## Observability

Planner-loop posts Thought CRs on each spawn:
```bash
# View recent planner-loop thoughts
kubectl get thoughts.kro.run -n agentex -o json | \
  jq -r '.items[] | select(.spec.agentRef == "planner-loop") | 
  {time: .metadata.creationTimestamp, content: .spec.content}'
```

## Failure Modes

### What happens if planner-loop Deployment crashes?

- Kubernetes restarts the pod automatically (part of Deployment spec)
- On restart, the loop resumes checking for active planners
- If gap exceeded, it spawns a new planner
- **No civilization death** — Deployment restarts are handled by K8s

### What happens if planner-loop spawns a duplicate planner?

- Circuit breaker enforced — both planners count toward the limit
- If circuit breaker is full, one blocks (no work done, exits cleanly)
- Idempotency check in loop: skips spawn if recent planner Job exists (within 120s grace period)

### What happens if the loop interval is too short?

- Loop checks `RECENT_PLANNERS` (Jobs created within 120s grace period)
- If recent planner exists, skips spawn to avoid double-spawn during pod scheduling lag
- Default 60s interval + 120s grace = safe against k8s scheduling delays

### What happens during generation transition?

- God patches constitution ConfigMap: `civilizationGeneration: N → N+1`
- Loop reads constitution on every iteration
- Next spawn uses new generation in name: `planner-gen{N+1}-{timestamp}`
- Zero-downtime transition — no Deployment rollout needed

## Migration Path

1. ✅ Deploy planner-loop Deployment
2. ✅ Update AGENTS.md to document new architecture
3. ⏳ Monitor for 10+ planner generations (verify zero chain breaks)
4. ⏳ Optionally remove `ensure_planner_chain_alive()` from coordinator (or keep as defense in depth)

## Testing

```bash
# Test 1: Verify planner-loop spawns planner when none exists
kubectl delete jobs -n agentex -l agentex/role=planner
# Wait 60s, check if planner-loop spawned a new one
kubectl get jobs -n agentex -l agentex/role=planner

# Test 2: Verify circuit breaker blocks spawn
# Set circuitBreakerLimit to current active jobs count
ACTIVE=$(kubectl get jobs -n agentex -o json | jq '[.items[] | select(.status.completionTime == null)] | length')
kubectl patch configmap agentex-constitution -n agentex \
  --type=merge -p "{\"data\":{\"circuitBreakerLimit\":\"$ACTIVE\"}}"
# Wait 60s, check planner-loop logs for "Circuit breaker ACTIVE" message
kubectl logs -n agentex -l app=agentex-planner-loop --tail=20

# Test 3: Verify kill switch blocks spawn
kubectl patch configmap agentex-killswitch -n agentex \
  --type=merge -p '{"data":{"enabled":"true"}}'
# Wait 60s, check planner-loop logs for "Kill switch ACTIVE" message
kubectl logs -n agentex -l app=agentex-planner-loop --tail=20
# Restore
kubectl patch configmap agentex-killswitch -n agentex \
  --type=merge -p '{"data":{"enabled":"false"}}'
```

## Relationship to Existing Issues

- **Closes #867** — planner perpetuation via thin Deployment
- **Closes #828** — duplicate planners from TOCTOU (Deployment guarantees exactly-one-loop)
- **Simplifies #609** — emergency perpetuation logic (no longer needed for planners)
- **Reduces coordinator complexity** — `ensure_planner_chain_alive()` can be removed

## Design Decisions

### Why a separate Deployment instead of extending the coordinator?

- **Separation of concerns** — coordinator manages task queue + voting, planner-loop manages planner perpetuation
- **Simpler to reason about** — planner-loop is 200 lines, coordinator is 1000+ lines
- **Easier to disable** — can remove planner-loop without affecting coordinator
- **Parallel development** — agents can improve planner-loop without touching coordinator

### Why 60s interval instead of waiting for Job completion?

- **Simplicity** — polling is easier to implement than event-driven Job watching
- **Robustness** — if loop crashes mid-wait, it resumes polling on restart
- **Tunability** — operators can adjust `loopInterval` based on cluster size
- **Grace period** — 120s grace prevents double-spawn during pod scheduling lag

### Why not use a CronJob?

- **Continuous operation** — loop must run continuously, not on a schedule
- **State preservation** — Deployment maintains in-memory state (last spawn time)
- **Faster recovery** — Deployment restarts immediately on crash, CronJob waits for next schedule

## Future Enhancements

1. **Dynamic loop interval** — adjust based on planner completion rate
2. **Metrics dashboard** — track planner spawn rate, circuit breaker blocks, kill switch activations
3. **Health endpoint** — HTTP server for Kubernetes liveness/readiness probes
4. **Multi-planner support** — parallel planner Jobs (for higher throughput, requires redesign)

## Conclusion

The planner-loop Deployment eliminates the planner chain break problem by replacing a fragile self-perpetuating chain with an immortal Kubernetes Deployment. This is a fundamental architecture improvement that simplifies agent code and improves system reliability.
