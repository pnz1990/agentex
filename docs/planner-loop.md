# Planner Loop — Deployment-Based Planner Perpetuation

## What This Is

The planner-loop is a **thin Deployment** that spawns planner Jobs with generational identity.
It eliminates chain breaks, TOCTOU races, and emergency perpetuation for planners.

## Architecture

```
planner-loop Deployment (replicas: 1, bash loop, no OpenCode)
  └── every 60s:
       1. check circuit breaker (read constitution circuitBreakerLimit)
       2. check kill switch
       3. if no active planner AND slot available: spawn planner-genN-timestamp
       4. repeat
```

## What This Solves

- ✅ **Exactly-one-planner** guaranteed by Kubernetes (`replicas: 1`) — no TOCTOU
- ✅ **No chain to break** — Deployment is immortal, Kubernetes keeps it alive
- ✅ **Zero-downtime generation transitions** — god patches constitution.civilizationGeneration → next planner Job uses new gen label
- ✅ **Eliminates emergency perpetuation for planners** — coordinator watchdog no longer needed
- ✅ **Planners stop spawning successors** — simpler entrypoint.sh, one fewer Prime Directive step
- ✅ **Generational identity preserved** — planner Jobs still get `agentex/generation` label, persistent identity names, N+2 planning state

## What Stays the Same

- Planner Jobs: still mortal, still run OpenCode, still have generational identity
- Circuit breaker: still enforced (loop checks before spawning)
- Workers: unchanged — coordinator already does this for workers
- God interface: advancing generation = patch constitution ConfigMap

## Deployment

### Bootstrap (new installation)

```bash
# Apply the RGD
kubectl apply -f manifests/rgds/planner-loop-graph.yaml

# Create the PlannerLoop CR (instantiates Deployment)
kubectl apply -f manifests/bootstrap/planner-loop.yaml

# Verify deployment is running
kubectl get deployment planner-loop -n agentex
kubectl get pods -l app=agentex-planner-loop -n agentex
```

### Migration (existing cluster with running planners)

1. **Wait for current planner to complete** — do not interrupt running planners
2. **Apply the RGD and CR** — planner-loop starts monitoring
3. **Planner-loop detects no active planner** — spawns next planner within 60s
4. **Future planners do NOT spawn successors** — loop handles perpetuation

```bash
# Check if planner is currently active
kubectl get jobs -n agentex -l agentex/role=planner --field-selector status.active=1

# If active, wait for it to complete
kubectl wait --for=condition=complete job/<planner-job-name> -n agentex --timeout=10m

# Apply planner-loop
kubectl apply -f manifests/rgds/planner-loop-graph.yaml
kubectl apply -f manifests/bootstrap/planner-loop.yaml

# Monitor planner-loop logs
kubectl logs -f deployment/planner-loop -n agentex
```

## How Planners Change

**Before (issue #867):**
- Planners spawn their own successors via `spawn_task_and_agent()`
- Emergency perpetuation spawns recovery planners on chain breaks
- Coordinator watchdog spawns recovery planners after 5min gap
- Chain breaks cause civilization downtime
- TOCTOU races cause duplicate planners

**After (issue #867):**
- Planners do NOT spawn successors (planner-loop handles this)
- Planners still spawn workers for open issues
- Planners still do platform audits and fixes
- Prime Directive step ① does not apply to planners
- Emergency perpetuation no longer spawns planners

## Monitoring

```bash
# Check planner-loop pod status
kubectl get pods -l app=agentex-planner-loop -n agentex

# View planner-loop logs
kubectl logs -f deployment/planner-loop -n agentex

# Check active planners
kubectl get jobs -n agentex -l agentex/role=planner --field-selector status.active=1

# CloudWatch metrics
aws cloudwatch get-metric-statistics \
  --namespace Agentex \
  --metric-name PlannerSpawned \
  --dimensions Name=Component,Value=PlannerLoop \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

## Troubleshooting

### Planner-loop pod is CrashLooping
```bash
# Check logs for error
kubectl logs deployment/planner-loop -n agentex

# Common issues:
# - kubectl config failure (check ServiceAccount permissions)
# - Constitution ConfigMap missing
# - Circuit breaker stuck at 0 (check coordinator-state.spawnSlots)
```

### No planners spawning
```bash
# Check circuit breaker status
kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.spawnSlots}'
kubectl get jobs -n agentex --field-selector status.active=1 | wc -l

# Check kill switch
kubectl get configmap agentex-killswitch -n agentex -o jsonpath='{.data.enabled}'

# Check planner-loop logs for spawn attempts
kubectl logs deployment/planner-loop -n agentex | grep "Spawning planner"
```

### Multiple planners running simultaneously
```bash
# This should not happen (planner-loop checks active planners before spawning)
# If it does, check for:
# - Multiple planner-loop pods (should be exactly 1)
kubectl get pods -l app=agentex-planner-loop -n agentex

# - Race condition in kro Job creation (Job exists but not marked active yet)
# This is a ~10s window, should self-correct on next iteration
```

## Files Changed

- `images/runner/planner-loop.sh` — new loop script
- `manifests/rgds/planner-loop-graph.yaml` — new RGD
- `manifests/bootstrap/planner-loop.yaml` — new CR
- `images/runner/Dockerfile` — copy planner-loop.sh
- `images/runner/coordinator.sh` — removed `ensure_planner_chain_alive()` watchdog
- `AGENTS.md` — updated Prime Directive, Architecture, and planner role docs

## Related Issues

- Closes #867 (planner perpetuation Deployment proposal)
- Fixes #828 (duplicate planners from TOCTOU)
- Simplifies #609 (emergency perpetuation logic)
- Removes coordinator watchdog (#792)
