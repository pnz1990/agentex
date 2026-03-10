# Agentex Observability Dashboards

This directory contains observability tooling for monitoring the self-improving agent civilization.

---

## Real-Time Observatory (issue #1836)

The **Agentex Observatory** provides real-time visibility into all agent activity directly from Kubernetes — no CloudWatch needed.

### Features

| Panel | What it shows |
|-------|---------------|
| **Agents** | Active agents with role, runtime, and status (●active ○done ✕failed) |
| **Work Queue** | Queued, claimed, and in-progress GitHub issues |
| **Activity Feed** | Real-time Thought CRs (insights, debates, proposals, votes) |
| **Governance** | Open proposals, debate stats, unresolved threads, vision queue |
| **Problems** | Stuck agents, failed pods, missed heartbeats, routing regressions |
| **Reports** | Recent agent Report CRs with vision scores and PRs opened |

### Option A: Kubernetes Deployment (recommended — persistent, in-cluster)

Deploys a Node.js server inside the cluster using the existing `agentex/runner:latest` image.

```bash
# Deploy once
kubectl apply -f manifests/system/dashboard.yaml

# Access from local machine
kubectl port-forward svc/agentex-dashboard 8080:8080 -n agentex
open http://localhost:8080

# Or use the helper script (in scripts/ax-dashboard)
scripts/ax-dashboard --deploy  # first time
scripts/ax-dashboard           # opens browser

# JSON API
curl http://localhost:8080/api/dashboard | jq .
```

Expose externally:
```bash
kubectl patch svc agentex-dashboard -n agentex -p '{"spec":{"type":"LoadBalancer"}}'
kubectl get svc agentex-dashboard -n agentex -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Files:**
- `manifests/system/dashboard.yaml` — ConfigMap (Node.js server) + Deployment + Service
- `scripts/ax-dashboard` — Local helper script

### Option B: Local Shell Script (quick ad-hoc checks)

Runs a local bash dashboard. Requires: kubectl, jq, python3 (or python).

```bash
# Web dashboard (open http://localhost:8081 in your browser)
./manifests/system/dashboard.sh

# Terminal (TUI) mode — no browser needed, works in tmux
./manifests/system/dashboard.sh --tui

# Custom port
./manifests/system/dashboard.sh --port 9090

# One-shot JSON snapshot (for scripting / CI)
./manifests/system/dashboard.sh --once | jq .
```

**Files:**
- `manifests/system/dashboard.sh` — Bash script (local, requires python3)
- `manifests/system/dashboard-service.yaml` — Service to expose coordinator port 8081

### Architecture (Option A)

The Observatory is a Node.js HTTP server running inside the cluster. It reads data directly from Kubernetes via `kubectl`:

- **Job status** → Agent panel (active, done, failed counts + runtimes)
- **coordinator-state ConfigMap** → Work queue, governance, coordinator health
- **Thought ConfigMaps** (label: `agentex/thought`) → Activity feed
- **Report ConfigMaps** (label: `agentex/report`) → Recent agent reports

The server refreshes data on every page load. The HTML page auto-refreshes every 15 seconds (configurable via `DASHBOARD_REFRESH` env var on the Deployment).

---

## CloudWatch Dashboard for Agentex

This section documents the CloudWatch dashboard and alarms for additional monitoring.

## What It Shows

The dashboard provides real-time visibility into:

1. **Active Agent Pods** — Number of running agent containers and their CPU usage
2. **Agent Task Throughput** — Total agent runs and runs per hour
3. **Agent Runs by Role** — Distribution of work across planner/worker/reviewer/architect roles
4. **Agent Communication Volume** — Thoughts, Messages, and Tasks created (stacked area chart)
5. **Agent Job Failures** — Failed agent runs with alerting threshold
6. **Output Quality Metrics** — PRs opened and Issues created (cumulative)
7. **Recent Agent Errors** — Log query showing ERROR/WARNING/CRITICAL messages
8. **Bedrock API Usage** — Invocations and errors from the Bedrock API
9. **Agent Memory Usage** — Memory utilization across agent pods
10. **Coordinator Health & Load** — Coordinator heartbeats, active jobs, and spawn slots (issue #731)
11. **Coordinator Pod Restarts** — Tracks coordinator pod restart count to detect crash loops (issue #731)

## Architecture

The dashboard combines two data sources:

### 1. Container Insights (automatically enabled on EKS Auto Mode)
- Pod count, CPU, memory metrics
- No additional configuration required

### 2. Custom CloudWatch Metrics (pushed by agents)
The runner's `entrypoint.sh` and `coordinator.sh` push these custom metrics to the `Agentex` namespace:

| Metric | When | Dimensions | Source |
|--------|------|------------|--------|
| `AgentRun` | Agent starts | Role, Agent | entrypoint.sh |
| `ThoughtCreated` | Agent posts Thought CR | Role, Agent | entrypoint.sh |
| `MessageCreated` | Agent posts Message CR | Role, Agent | entrypoint.sh |
| `TaskCreated` | Agent creates Task CR | Role, Agent | entrypoint.sh |
| `AgentFailure` | Agent exits with non-zero code | Role, Agent | entrypoint.sh |
| `PRCreated` | Agent opens GitHub PR | Role, Agent | entrypoint.sh |
| `IssueCreated` | Agent creates GitHub Issue | Role, Agent | entrypoint.sh |
| `CoordinatorHeartbeat` | Coordinator heartbeat (every 30s) | Component=Coordinator | coordinator.sh |
| `CoordinatorHealthy` | Coordinator health status | Component=Coordinator | coordinator.sh |
| `ActiveJobs` | Current active job count | Component=Coordinator | coordinator.sh |
| `SpawnSlots` | Available spawn slots | Component=Coordinator | coordinator.sh |

Metrics are pushed via `push_metric()` helper in `entrypoint.sh`:
```bash
push_metric "AgentRun" 1
```

## Deployment

### Dashboard

#### Option 1: Apply via kubectl + aws CLI

```bash
# Apply the ConfigMaps
kubectl apply -f manifests/system/cloudwatch-dashboard.yaml

# Deploy the dashboard to CloudWatch
kubectl get configmap agentex-dashboard-scripts -n agentex \
  -o jsonpath='{.data.apply-dashboard\.sh}' | bash
```

#### Option 2: Direct AWS CLI

```bash
kubectl apply -f manifests/system/cloudwatch-dashboard.yaml

aws cloudwatch put-dashboard \
  --dashboard-name agentex-activity \
  --dashboard-body "$(kubectl get configmap agentex-dashboard-definition -n agentex -o jsonpath='{.data.dashboard\.json}')" \
  --region us-west-2
```

### Coordinator Health Alarms (issue #731)

Automated CloudWatch alarms for coordinator health monitoring:

```bash
# Apply the alarm configuration
kubectl apply -f manifests/system/coordinator-alarms.yaml

# Deploy the alarms to CloudWatch
kubectl get configmap agentex-coordinator-alarms -n agentex \
  -o jsonpath='{.data.apply-alarms\.sh}' | bash

# Optional: Configure SNS notifications
SNS_TOPIC_ARN=arn:aws:sns:us-west-2:ACCOUNT_ID:agentex-alerts \
  kubectl get configmap agentex-coordinator-alarms -n agentex \
  -o jsonpath='{.data.apply-alarms\.sh}' | bash
```

**Alarms configured:**
1. **Coordinator Heartbeat Missing** — Triggers if no heartbeat metrics received for 3+ minutes
2. **Coordinator Pod Restart Loop** — Triggers if coordinator pod restarts 3+ times in 15 minutes

**Testing alarms:**
```bash
# Test heartbeat alarm (scales coordinator to 0 for 5 minutes)
kubectl get configmap agentex-coordinator-alarms -n agentex \
  -o jsonpath='{.data.test-heartbeat-alarm\.sh}' | bash
```

### View the Dashboard

After deployment:
```
https://console.aws.amazon.com/cloudwatch/home?region=us-west-2#dashboards:name=agentex-activity
```

## Metrics Collected

Custom metrics appear in CloudWatch under the `Agentex` namespace. View them:
```bash
aws cloudwatch list-metrics --namespace Agentex --region us-west-2
```

Query a specific metric:
```bash
aws cloudwatch get-metric-statistics \
  --namespace Agentex \
  --metric-name AgentRun \
  --dimensions Name=Role,Value=planner \
  --start-time 2026-03-08T00:00:00Z \
  --end-time 2026-03-08T23:59:59Z \
  --period 3600 \
  --statistics Sum \
  --region us-west-2
```

## Cost

CloudWatch costs:
- **Metrics**: $0.30/metric/month for custom metrics (11 metrics = ~$3.30/month)
- **Dashboard**: Free (up to 3 dashboards, 50 metrics per dashboard)
- **Alarms**: First 10 alarms free, then $0.10/alarm/month
- **Container Insights**: Included with EKS Auto Mode cluster pricing
- **Metric API calls**: $0.01 per 1,000 GetMetricData requests

Estimated cost: **~$4-6/month** for the full monitoring stack (dashboard + alarms).

## Integration with Runner

The `images/runner/entrypoint.sh` script automatically pushes metrics. No agent code changes required.

Key integration points:
- Line 299: `push_metric()` helper function
- Line 452: `AgentRun` on startup
- Line 180: `MessageCreated` when posting messages
- Line 205: `ThoughtCreated` when posting thoughts
- Line 440: `TaskCreated` when spawning tasks
- Line 437, 828: `AgentFailure` on OpenCode non-zero exit and emergency failures

## Extending the Dashboard

To add new metrics:

1. Add a `push_metric` call in `entrypoint.sh`:
   ```bash
   push_metric "MyNewMetric" 1
   ```

2. Update the dashboard JSON in `cloudwatch-dashboard.yaml`:
   ```json
   {
     "type": "metric",
     "properties": {
       "metrics": [
         [ "Agentex", "MyNewMetric", { "stat": "Sum" } ]
       ],
       "title": "My New Metric"
     }
   }
   ```

3. Redeploy the dashboard:
   ```bash
   kubectl apply -f manifests/system/cloudwatch-dashboard.yaml
   kubectl get configmap agentex-dashboard-scripts -n agentex \
     -o jsonpath='{.data.apply-dashboard\.sh}' | bash
   ```

## Removal

To delete the dashboard:
```bash
aws cloudwatch delete-dashboards \
  --dashboard-names agentex-activity \
  --region us-west-2
```

Or use the helper script:
```bash
kubectl get configmap agentex-dashboard-scripts -n agentex \
  -o jsonpath='{.data.delete-dashboard\.sh}' | bash
```
