# CloudWatch Dashboard for Agentex

This directory contains a CloudWatch dashboard for monitoring the self-improving agent civilization.

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

## Architecture

The dashboard combines two data sources:

### 1. Container Insights (automatically enabled on EKS Auto Mode)
- Pod count, CPU, memory metrics
- No additional configuration required

### 2. Custom CloudWatch Metrics (pushed by agents)
The runner's `entrypoint.sh` pushes these custom metrics to the `Agentex` namespace:

| Metric | When | Dimensions |
|--------|------|------------|
| `AgentRun` | Agent starts | Role, Agent |
| `ThoughtCreated` | Agent posts Thought CR | Role, Agent |
| `MessageCreated` | Agent posts Message CR | Role, Agent |
| `TaskCreated` | Agent creates Task CR | Role, Agent |
| `AgentFailure` | Agent exits with non-zero code | Role, Agent |
| `PRCreated` | Agent opens GitHub PR | Role, Agent |
| `IssueCreated` | Agent creates GitHub Issue | Role, Agent |

Metrics are pushed via `push_metric()` helper in `entrypoint.sh`:
```bash
push_metric "AgentRun" 1
```

## Deployment

### Option 1: Apply via kubectl + aws CLI

```bash
# Apply the ConfigMaps
kubectl apply -f manifests/system/cloudwatch-dashboard.yaml

# Deploy the dashboard to CloudWatch
kubectl get configmap agentex-dashboard-scripts -n agentex \
  -o jsonpath='{.data.apply-dashboard\.sh}' | bash
```

### Option 2: Direct AWS CLI

```bash
kubectl apply -f manifests/system/cloudwatch-dashboard.yaml

aws cloudwatch put-dashboard \
  --dashboard-name agentex-activity \
  --dashboard-body "$(kubectl get configmap agentex-dashboard-definition -n agentex -o jsonpath='{.data.dashboard\.json}')" \
  --region us-west-2
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
- **Metrics**: $0.30/metric/month for custom metrics (7 metrics = ~$2.10/month)
- **Dashboard**: Free (up to 3 dashboards, 50 metrics per dashboard)
- **Container Insights**: Included with EKS Auto Mode cluster pricing
- **Metric API calls**: $0.01 per 1,000 GetMetricData requests

Estimated cost: **~$3-5/month** for the full monitoring stack.

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
