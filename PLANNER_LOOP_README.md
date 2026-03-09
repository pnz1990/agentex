# Planner Loop Architecture (Issue #867)

## Overview

This PR implements a **planner-loop Deployment** that replaces the fragile self-perpetuating planner Job chain with a simple, immortal loop that spawns planners automatically.

## Problem Statement

The previous architecture had planners spawn their own successors:
```
planner-001 → planner-002 → planner-003 → ...
```

This had several issues:
- **TOCTOU race** (issue #828): Two planners completing simultaneously both trigger emergency perpetuation → duplicate planners
- **Fragile chain**: If one planner fails to spawn successor, entire system stops
- **Complex emergency perpetuation**: Coordinator watchdog `ensure_planner_chain_alive()` exists solely to patch chain breaks
- **Entrypoint complexity**: ~200 lines of spawn control logic in every agent

## Solution

Replace the Job chain with a thin Deployment loop:

```
planner-loop Deployment (immortal, replicas: 1)
  └── spawns planner Jobs when:
      - No planner currently active
      - Circuit breaker permits (active jobs < limit)
      - Kill switch inactive
```

## Architecture Changes

### New Components

1. **`images/runner/planner-loop.sh`** — Simple bash loop that:
   - Checks every 60s for active planner
   - Spawns planner Job if conditions met
   - Never exits (Kubernetes keeps it alive)

2. **`manifests/rgds/planner-loop-graph.yaml`** — RGD that creates Deployment from PlannerLoop CR

3. **`manifests/bootstrap/planner-loop.yaml`** — Bootstrap CR to deploy the loop

### Modified Files

1. **`images/runner/Dockerfile`** — Added planner-loop.sh to image

2. **`AGENTS.md`** — Updated Prime Directive:
   - Planners: Skip step ① (no self-perpetuation needed)
   - Workers/reviewers/architects: Still spawn successors
   - Added "Planner Loop Architecture" section explaining the change

## Benefits

- ✅ **Eliminates TOCTOU race** — Kubernetes `replicas: 1` guarantees exactly one loop
- ✅ **No chain to break** — Deployment is immortal, not fragile Job chain
- ✅ **Simpler planner code** — Planners focus on work, not perpetuation
- ✅ **Coordinator cleanup** — `ensure_planner_chain_alive()` can be removed (future PR)
- ✅ **Easier generation transitions** — God patches constitution, loop reads new value

## What Stays the Same

- Planner Jobs still have generational identity (persistent names, N+2 planning)
- Circuit breaker still enforced (loop checks before spawning)
- Workers/reviewers/architects still self-perpetuate
- Emergency perpetuation still exists for non-planner roles

## Deployment Steps

1. **Apply RGD:**
   ```bash
   kubectl apply -f manifests/rgds/planner-loop-graph.yaml
   ```

2. **Build and push new runner image:**
   ```bash
   cd images/runner
   docker build -t 569190534191.dkr.ecr.us-west-2.amazonaws.com/agentex/runner:latest .
   docker push 569190534191.dkr.ecr.us-west-2.amazonaws.com/agentex/runner:latest
   ```

3. **Deploy planner loop:**
   ```bash
   kubectl apply -f manifests/bootstrap/planner-loop.yaml
   ```

4. **Wait for loop to start:**
   ```bash
   kubectl wait --for=condition=available --timeout=60s deployment/planner-loop -n agentex
   ```

5. **Monitor loop logs:**
   ```bash
   kubectl logs -n agentex -l app=agentex-planner-loop -f
   ```

## Testing

1. **Verify loop spawns planners:**
   ```bash
   # Wait for loop to spawn first planner
   sleep 120
   kubectl get jobs -n agentex -l agentex/role=planner
   ```

2. **Verify exactly-one-planner guarantee:**
   ```bash
   # Count active planners (should be 0 or 1, never >1)
   kubectl get jobs -n agentex -o json | jq '[.items[] | 
     select(.status.completionTime == null and (.status.active // 0) > 0) |
     select(.metadata.name | test("planner"))] | length'
   ```

3. **Verify circuit breaker respected:**
   ```bash
   # Manually spawn jobs until circuit breaker triggers
   # Then verify loop doesn't spawn planner
   ```

## Future Work

- **Remove coordinator watchdog** — `ensure_planner_chain_alive()` becomes redundant
- **Extend to workers** — Could create worker-loop for workers too (but coordinator already handles this via task queue)
- **Metrics** — Add CloudWatch metrics for planner spawns, loop health

## Related Issues

- Closes #867 (architecture proposal)
- Closes #828 (TOCTOU duplicate planners)
- Simplifies #609 (emergency perpetuation complexity)
