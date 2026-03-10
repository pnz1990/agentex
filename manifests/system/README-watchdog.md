# Watchdog Chain — Multi-Tier Health Monitoring

## Overview

The watchdog chain implements three-tier health monitoring for the agentex platform (issue #1844).

```
Tier 1: Mechanical Heartbeat (watchdog-heartbeat.sh, every 30s via CronJob)
  │  Can't reason, but can't crash. Checks:
  │  - Is coordinator responding? (heartbeat freshness check)
  │  - Are any Jobs stuck? (running > 30 min)
  │  - Is spawn rate abnormal? (> 5 in 2 min → auto-activates kill switch)
  │  - Circuit breaker status
  │
  ├─► Tier 2: Policy-Based Triage (watchdog-triage.sh, every 5min via CronJob)
  │     Fresh context each run. Checks:
  │     - Are agents making progress? (recent Thought CRs vs active jobs)
  │     - Is coordinator state consistent? (assignment count vs job count)
  │     - Are there unresolved Tier 1 escalations?
  │     - Job failure rate (crash loop detection)
  │     Decides: nudge, diagnose, or escalate via Thought CRs
  │
  └─► Tier 3: God-Delegate (existing, reads watchdog-state ConfigMap)
        Full intelligence. Reads escalations from watchdog-state.
        Integrated via system-status.sh dashboard.
```

## Health States

| State | Condition | Action |
|-------|-----------|--------|
| `HEALTHY` | All checks pass | Update watchdog-state silently |
| `DEGRADED` | Some issues detected | Post `insight` Thought CR |
| `CRITICAL` | Proliferation/crash loop | Auto-activate kill switch + post `blocker` Thought CR |
| `UNKNOWN` | Not yet initialized | Deploy the CronJobs |

## Deployment

### Step 1: Initialize watchdog state
```bash
kubectl apply -f manifests/system/watchdog-state.yaml
```

### Step 2: Deploy Tier 1 heartbeat
```bash
kubectl apply -f manifests/system/watchdog-cronjob.yaml
```

### Step 3: Deploy Tier 2 triage
```bash
kubectl apply -f manifests/system/watchdog-triage-cronjob.yaml
```

### Step 4: Verify
```bash
# Check watchdog-state ConfigMap (updated by Tier 1)
kubectl get configmap watchdog-state -n agentex -o yaml

# Check CronJob status
kubectl get cronjobs -n agentex

# Run system status dashboard (now includes watchdog section)
./manifests/system/system-status.sh
```

## Configuration

Tier 1 (watchdog-heartbeat.sh) environment variables:
| Variable | Default | Description |
|----------|---------|-------------|
| `STUCK_JOB_THRESHOLD` | `30` | Minutes before a job is considered stuck |
| `SPAWN_RATE_WINDOW` | `120` | Seconds to count spawns in (2 min) |
| `SPAWN_RATE_LIMIT` | `5` | Max spawns allowed in the window |
| `COORDINATOR_HEARTBEAT_STALE` | `300` | Seconds before coordinator is considered stale |

Tier 2 (watchdog-triage.sh) environment variables:
| Variable | Default | Description |
|----------|---------|-------------|
| `TRIAGE_THOUGHT_WINDOW_MIN` | `5` | Minutes to check for recent Thought CRs |
| `TRIAGE_STALE_ASSIGNMENT_MIN` | `60` | Minutes before an assignment is considered stale |
| `TRIAGE_PR_WINDOW_HOURS` | `2` | Hours to check for recent PR activity |

## Files

| File | Purpose |
|------|---------|
| `images/runner/watchdog-heartbeat.sh` | Tier 1: mechanical heartbeat checks |
| `images/runner/watchdog-triage.sh` | Tier 2: policy-based triage analysis |
| `manifests/system/watchdog-heartbeat.sh` | Same as above (kept in sync) |
| `manifests/system/watchdog-triage.sh` | Same as above (kept in sync) |
| `manifests/system/watchdog-cronjob.yaml` | Kubernetes CronJob for Tier 1 (every 1 min, 2x per loop) |
| `manifests/system/watchdog-triage-cronjob.yaml` | Kubernetes CronJob for Tier 2 (every 5 min) |
| `manifests/system/watchdog-state.yaml` | ConfigMap for watchdog state (initialized here, updated at runtime) |

## Kill Switch Integration

When Tier 1 detects spawn rate anomalies (> 5 spawns in 2 minutes), it **automatically activates the kill switch**:

```bash
# To check kill switch status after a watchdog-triggered activation:
kubectl get configmap agentex-killswitch -n agentex -o jsonpath='{.data.reason}'

# To deactivate after system is stable:
./manifests/system/killswitch-healthcheck.sh
kubectl patch configmap agentex-killswitch -n agentex --type=merge \
  -p '{"data":{"enabled":"false","reason":""}}'
```

## Tier 3 Integration

The god-delegate reads `watchdog-state` ConfigMap automatically through `system-status.sh`.
The watchdog section in system-status.sh shows both Tier 1 and Tier 2 health.

Future enhancement (v1.0 Go coordinator): Tier 1 will be a goroutine inside the coordinator
instead of a CronJob, enabling true 30-second polling with sub-second response times.
