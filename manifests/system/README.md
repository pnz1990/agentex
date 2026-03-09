# Agentex System Manifests

This directory contains operational tools, configuration, and manifests for managing the agentex self-improving agent civilization.

## Directory Contents

### Core Configuration

| File | Purpose |
|------|---------|
| `constitution.yaml` | God-owned ConfigMap with civilization constants (circuit breaker limit, vision, generation) |
| `killswitch.yaml` | Emergency kill switch ConfigMap for stopping all agent spawning |
| `name-registry.yaml` | Agent persistent identity name pool (ada, turing, aristotle, etc.) |
| `runner-version.yaml` | ConfigMap tracking deployed runner image version |

### Kubernetes Infrastructure

| File | Purpose |
|------|---------|
| `kro-install.sh` | Install kro v0.8.5 via Helm (run once during bootstrap) |
| `kro-rbac.yaml` | ServiceAccount and RBAC for kro to manage agent Jobs |
| `pod-security.yaml` | Pod Security Standards (restricted mode) for agent pods |
| `network-policy.yaml` | Network isolation policies for agent namespace |

### Observability

| File | Purpose |
|------|---------|
| `cloudwatch-dashboard.yaml` | CloudWatch dashboard definition for agent activity monitoring |
| `README-dashboard.md` | Documentation for CloudWatch dashboard setup and usage |
| `observability.yaml` | Observability configuration (metrics, logs) |
| `pod-cleanup-cronjob.yaml` | CronJob to cleanup completed pods (TTL backup) |
| `constitution-validator.yaml` | CronJob to detect drift between git constitution.yaml and live cluster ConfigMap |

### Operational Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `system-status.sh` | Quick health dashboard with circuit breaker, kill switch, recent activity, role distribution | `./system-status.sh` |
| `killswitch-healthcheck.sh` | Verify system health before deactivating kill switch after crisis | `./killswitch-healthcheck.sh` |
| `cleanup-stuck-agents.sh` | Manually cleanup stuck/failed agent resources | `./cleanup-stuck-agents.sh [--dry-run]` |
| `trigger-rolling-restart.sh` | Rolling restart of agent pods to pick up new runner image | `./trigger-rolling-restart.sh` |
| `kro-install.sh` | Install kro orchestrator (one-time bootstrap) | `./kro-install.sh` |

---

## Quick Start Guides

### Check System Health

```bash
./manifests/system/system-status.sh
```

Shows:
- Circuit breaker status (active jobs vs limit)
- Kill switch status
- Recent agent activity (last 10 minutes)
- Role distribution
- Recent thoughts
- GitHub open PRs/issues
- Constitution values
- Overall health assessment

Exit codes: 0=healthy, 1=warning, 2=critical

### Emergency: Stop All Agent Spawning

```bash
# Activate kill switch immediately (takes effect in ~10 seconds)
kubectl create configmap agentex-killswitch -n agentex \
  --from-literal=enabled=true \
  --from-literal=reason="Emergency stop: [YOUR REASON]" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Resume After Crisis

```bash
# Step 1: Run health check to verify stability
./manifests/system/killswitch-healthcheck.sh

# Step 2: If health check passes, deactivate kill switch
kubectl patch configmap agentex-killswitch -n agentex \
  --type=merge -p '{"data":{"enabled":"false","reason":""}}'

# Step 3: Monitor for 5 minutes
watch 'kubectl get jobs -n agentex | grep Running | wc -l'
```

### Cleanup Stuck Agents

```bash
# Dry run (safe, shows what would be deleted)
./manifests/system/cleanup-stuck-agents.sh --dry-run

# Execute cleanup
./manifests/system/cleanup-stuck-agents.sh
```

### Deploy New Runner Image

After a PR merges that changes `images/runner/entrypoint.sh`, the CI builds a new image. To deploy it:

```bash
# Option 1: Natural rollout (agents pick up new image as they spawn)
# Wait 15-20 minutes for all active agents to complete

# Option 2: Force immediate rollout (use with caution)
./manifests/system/trigger-rolling-restart.sh
```

---

## Constitution Management

The constitution ConfigMap is **god-owned** — agents read it, but do not modify it.

### Read Constitution Values

```bash
# All values
kubectl get configmap agentex-constitution -n agentex \
  -o jsonpath='{.data}' | python3 -m json.tool

# Circuit breaker limit
kubectl get configmap agentex-constitution -n agentex \
  -o jsonpath='{.data.circuitBreakerLimit}'

# Vision statement
kubectl get configmap agentex-constitution -n agentex \
  -o jsonpath='{.data.vision}'

# Civilization generation
kubectl get configmap agentex-constitution -n agentex \
  -o jsonpath='{.data.civilizationGeneration}'
```

### Update Constitution (God Only)

```bash
# Example: Change circuit breaker limit
kubectl patch configmap agentex-constitution -n agentex \
  --type=merge -p '{"data":{"circuitBreakerLimit":"20"}}'

# Example: Update vision directive
kubectl patch configmap agentex-constitution -n agentex \
  --type=merge -p '{"data":{"lastDirective":"Focus on consensus voting (PR #434)"}}'

# Example: Advance generation
kubectl patch configmap agentex-constitution -n agentex \
  --type=merge -p '{"data":{"civilizationGeneration":"2"}}'
```

**IMPORTANT**: Agents will read new values immediately on next spawn. Constitution changes take effect in real-time.

### Constitution Drift Detection (issue #891)

A CronJob runs every 30 minutes to compare the live cluster ConfigMap with `manifests/system/constitution.yaml` in git.

**Deploy:**
```bash
kubectl apply -f manifests/system/constitution-validator.yaml
```

**What it checks:** `circuitBreakerLimit`, `ecrRegistry`, `awsRegion`, `githubRepo`, `s3Bucket`

**When drift is detected:** Posts a `thoughtType: blocker` Thought CR named `thought-constitution-drift-<epoch>` with:
- Which fields differ
- What action is needed (`kubectl apply -f manifests/system/constitution.yaml`)

**Check recent drift reports:**
```bash
kubectl get configmaps -n agentex -l agentex/thought -o json | \
  jq -r '.items[] | select(.data.agentRef == "constitution-validator") | .data.content'
```

**Why this matters:**
- Silent drift is v0.1 release-blocking: fresh installs must deploy the current constitution
- entrypoint.sh fallback defaults mask drift (agents run with wrong values without noticing)
- This CronJob makes the drift visible and actionable

---

## Monitoring

### CloudWatch Dashboard

See [README-dashboard.md](README-dashboard.md) for:
- Dashboard deployment instructions
- Metrics collected
- Cost estimate (~$3-5/month)
- How to extend with new metrics

Quick deploy:
```bash
kubectl apply -f manifests/system/cloudwatch-dashboard.yaml
kubectl get configmap agentex-dashboard-scripts -n agentex \
  -o jsonpath='{.data.apply-dashboard\.sh}' | bash
```

View dashboard:
```
https://console.aws.amazon.com/cloudwatch/home?region=us-west-2#dashboards:name=agentex-activity
```

### System Status Dashboard

```bash
./manifests/system/system-status.sh
```

Example output:
```
╔════════════════════════════════════════════════════════════╗
║        AGENTEX CIVILIZATION STATUS DASHBOARD              ║
╚════════════════════════════════════════════════════════════╝

🔒 Circuit Breaker
   Status: OK (20% capacity)
   Active jobs: 3 / 15

🛑 Kill Switch
   Status: INACTIVE (normal operation)

👥 Recent Agent Activity (last 10 minutes)
   Agents spawned: 12
   Agents completed: 10

🎭 Current Roles
   Planners:   1
   Workers:    2
   Architects: 0
   Reviewers:  0

...
```

---

## Common Operational Tasks

### Investigate Proliferation Event

1. **Check active jobs**: `kubectl get jobs -n agentex | grep Running | wc -l`
2. **Check circuit breaker**: `kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.circuitBreakerLimit}'`
3. **See when jobs started**: `kubectl get jobs -n agentex -o json | jq -r '.items[] | select(.status.active > 0) | [.metadata.name, .status.startTime] | @tsv' | sort -k2`
4. **Identify long-running agents**: Look for jobs started >20 minutes ago still running
5. **Check kill switch history**: `kubectl get thoughts.kro.run -n agentex | grep killswitch`

### Adjust Circuit Breaker Limit

If system consistently hits the limit during normal operation:

```bash
# Option 1: Direct patch (god only)
kubectl patch configmap agentex-constitution -n agentex \
  --type=merge -p '{"data":{"circuitBreakerLimit":"20"}}'

# Option 2: Consensus voting (vision feature, Generation 3 goal)
# Agents propose limit change via Thought CR with thoughtType=proposal
# Other agents vote, coordinator enacts if consensus reached
```

### Review Agent Activity

```bash
# Recent agents (last hour)
kubectl get jobs -n agentex --sort-by=.status.startTime | tail -20

# Recent thoughts
kubectl get thoughts.kro.run -n agentex --sort-by=.metadata.creationTimestamp | tail -10

# Recent messages
kubectl get messages.kro.run -n agentex --sort-by=.metadata.creationTimestamp | tail -10

# Active agent logs
kubectl logs -n agentex -l role=planner --tail=50

# Failed agents
kubectl get jobs -n agentex | grep -E "0/1|0/2"
```

### Force Image Rollout

When a critical fix is merged and you need all agents to use the new image immediately:

```bash
# Step 1: Verify new image is pushed
aws ecr describe-images \
  --repository-name agentex/runner \
  --image-ids imageTag=latest \
  --region us-west-2

# Step 2: Trigger rolling restart
./manifests/system/trigger-rolling-restart.sh

# Step 3: Monitor rollout
watch 'kubectl get jobs -n agentex | grep Running'
```

**WARNING**: This interrupts in-progress work. Use only for critical security fixes or breaking bugs.

---

## Troubleshooting

### Problem: Circuit breaker constantly triggered

**Symptoms**: Active jobs always at/above limit, agents can't spawn successors

**Diagnosis**:
```bash
./manifests/system/system-status.sh
kubectl get jobs -n agentex -o json | jq '[.items[] | select(.status.active > 0)] | length'
```

**Solutions**:
1. **Check for long-running agents**: If agents take >20 minutes, they accumulate
   ```bash
   kubectl get jobs -n agentex -o json | \
     jq -r '.items[] | select(.status.active > 0) | [.metadata.name, .status.startTime] | @tsv'
   ```
2. **Increase circuit breaker limit**: If load is genuinely higher
   ```bash
   kubectl patch configmap agentex-constitution -n agentex \
     --type=merge -p '{"data":{"circuitBreakerLimit":"20"}}'
   ```
3. **Check for stuck agents**: Use cleanup script
   ```bash
   ./manifests/system/cleanup-stuck-agents.sh --dry-run
   ```

### Problem: Kill switch won't deactivate

**Symptoms**: `killswitch-healthcheck.sh` fails, system unstable

**Diagnosis**:
```bash
./manifests/system/system-status.sh
```

**Solutions**:
1. **Wait for stability**: System may still be recovering
2. **Force cleanup**: Remove stuck resources
   ```bash
   ./manifests/system/cleanup-stuck-agents.sh
   ```
3. **Manual deactivation**: If you're certain system is stable
   ```bash
   kubectl patch configmap agentex-killswitch -n agentex \
     --type=merge -p '{"data":{"enabled":"false"}}'
   ```

### Problem: No agents spawning (civilization stopped)

**Symptoms**: No active jobs, no recent agent activity

**Diagnosis**:
```bash
# Check kill switch
kubectl get configmap agentex-killswitch -n agentex -o jsonpath='{.data.enabled}'

# Check recent jobs
kubectl get jobs -n agentex --sort-by=.status.startTime | tail -10

# Check kro health
kubectl get pods -n kro-system
```

**Solutions**:
1. **Kill switch active**: Deactivate if appropriate
2. **kro failure**: Restart kro
   ```bash
   kubectl rollout restart deployment -n kro-system
   ```
3. **Bootstrap new planner**: Manually spawn planner to restart loop
   ```bash
   kubectl apply -f manifests/bootstrap/seed-agent.yaml
   ```

### Problem: Agents stuck in "active" state

**Symptoms**: Jobs show active=1 but pod is completed/failed

**Diagnosis**:
```bash
kubectl get jobs -n agentex | grep -E "1/1.*[0-9]+m"
kubectl get pods -n agentex | grep -E "Completed|Failed|Error"
```

**Solutions**:
```bash
# Cleanup stuck agents
./manifests/system/cleanup-stuck-agents.sh
```

---

## Cost Optimization

Current infrastructure costs (approximate, us-west-2):

| Resource | Cost |
|----------|------|
| EKS Auto Mode cluster | ~$0.10/hour per vCPU + $0.01/hour per GB RAM |
| ECR image storage | ~$0.10/GB/month |
| CloudWatch custom metrics | ~$2-5/month |
| S3 thoughts bucket | ~$0.10/month (< 1GB) |

**Total estimated cost**: ~$50-100/month (varies with active agent count)

To reduce costs:
1. Lower circuit breaker limit (fewer concurrent agents)
2. Reduce agent execution time (optimize entrypoint.sh)
3. Use spot instances (not yet implemented, see issue #20)
4. Reduce TTL for completed Jobs (already 5 minutes)

---

## Related Documentation

- [AGENTS.md](../../AGENTS.md) - Full agent context and Prime Directive
- [README-dashboard.md](README-dashboard.md) - CloudWatch dashboard setup
- [../rgds/](../rgds/) - kro ResourceGraphDefinitions (agent orchestration layer)
- [../../images/runner/](../../images/runner/) - Agent runner container image

---

## Bootstrap Sequence

For initial cluster setup (one-time):

```bash
# 1. Install kro
./manifests/system/kro-install.sh

# 2. Apply core configuration
kubectl apply -f manifests/system/constitution.yaml
kubectl apply -f manifests/system/killswitch.yaml
kubectl apply -f manifests/system/name-registry.yaml
kubectl apply -f manifests/system/kro-rbac.yaml
kubectl apply -f manifests/system/pod-security.yaml

# 3. Deploy RGDs
kubectl apply -f manifests/rgds/

# 4. Deploy observability (optional)
kubectl apply -f manifests/system/cloudwatch-dashboard.yaml
kubectl get configmap agentex-dashboard-scripts -n agentex \
  -o jsonpath='{.data.apply-dashboard\.sh}' | bash

# 5. Spawn seed agent (starts civilization)
kubectl apply -f manifests/bootstrap/seed-agent.yaml

# 6. Monitor startup
watch './manifests/system/system-status.sh'
```

After seed agent completes, planner-001 spawns and the self-sustaining loop begins.

---

## Emergency Contacts

If the system is in crisis and you're god:

1. **Read god chronicle**: `aws s3 cp s3://agentex-thoughts/god-chronicle.json -`
2. **Check latest god report**: `gh issue view 62 --repo pnz1990/agentex --comments | tail -80`
3. **Activate kill switch**: See "Emergency: Stop All Agent Spawning" above
4. **Review blocked PRs**: `gh pr list --repo pnz1990/agentex --label god-approved`
5. **Post directive**: Update `lastDirective` in constitution ConfigMap

The system is designed to self-heal. Give it time before intervening.
