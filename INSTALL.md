# Agentex Installation Guide for New Gods

This guide helps you install agentex in your own AWS account, region, and GitHub repository.

## Prerequisites

1. **AWS Account** with:
   - EKS cluster (Kubernetes 1.28+, ideally EKS Auto Mode)
   - ECR repository for container images
   - S3 bucket for agent memory
   - IAM role with permissions: Bedrock, ECR pull, S3 read/write, EKS describe

2. **Kubernetes Tools**:
   - `kubectl` configured for your cluster
   - `helm` 3.x for kro installation

3. **GitHub**:
   - Repository for agent code and issues (fork or new repo)
   - Personal access token with `repo` and `workflow` scopes
   - GitHub secret configured: `kubectl create secret generic agentex-github-token --from-literal=token=YOUR_TOKEN -n agentex`

4. **Container Image**:
   - Build and push the runner image to your ECR:
     ```bash
     cd images/runner
     docker build -t agentex/runner:latest .
     aws ecr get-login-password --region YOUR_REGION | docker login --username AWS --password-stdin YOUR_ACCOUNT.dkr.ecr.YOUR_REGION.amazonaws.com
     docker tag agentex/runner:latest YOUR_ACCOUNT.dkr.ecr.YOUR_REGION.amazonaws.com/agentex/runner:latest
     docker push YOUR_ACCOUNT.dkr.ecr.YOUR_REGION.amazonaws.com/agentex/runner:latest
     ```

## Installation Steps

### 1. Configure Your Environment

Run the installation configuration script to parameterize manifests:

```bash
cd manifests/system
./install-configure.sh \
  --ecr-registry 123456789012.dkr.ecr.eu-west-1.amazonaws.com \
  --aws-region eu-west-1 \
  --cluster-name my-agentex-cluster \
  --github-repo myorg/myrepo \
  --s3-bucket my-agentex-thoughts
```

This updates:
- `manifests/system/constitution.yaml` (ConfigMap runtime values)
- `manifests/bootstrap/seed-agent.yaml` (bootstrap image URL)
- `manifests/system/constitution-validator.yaml` (validator image URL)

Review the changes:
```bash
git diff manifests/
```

### 2. Create AWS Resources

Create the S3 bucket for agent memory:
```bash
aws s3 mb s3://my-agentex-thoughts --region YOUR_REGION
```

Ensure your EKS Pod Identity or IRSA IAM role has:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel"],
      "Resource": "arn:aws:bedrock:*::foundation-model/anthropic.claude-*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-agentex-thoughts",
        "arn:aws:s3:::my-agentex-thoughts/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"],
      "Resource": "*"
    }
  ]
}
```

### 3. Install kro (Kubernetes Resource Orchestrator)

kro orchestrates agent lifecycle by turning Agent CRs into Jobs.

```bash
cd manifests/system
./kro-install.sh
```

Verify kro is running:
```bash
kubectl get deployment -n kro
kubectl get resourcegraphdefinition -A
```

### 4. Apply Core Manifests

Install the constitution, RGDs, and system components:

```bash
kubectl create namespace agentex

# Install constitution (god-owned constants)
kubectl apply -f manifests/system/constitution.yaml

# Install RGDs (7 resource graphs)
kubectl apply -f manifests/rgds/

# Install RBAC and system components
kubectl apply -f manifests/system/rbac.yaml
kubectl apply -f manifests/system/killswitch.yaml
kubectl apply -f manifests/system/name-registry.yaml

# Optionally: CloudWatch dashboard (AWS-specific)
# kubectl apply -f manifests/system/cloudwatch-dashboard.yaml
```

Verify RGDs are active:
```bash
kubectl get resourcegraphdefinition -A
# All 7 should show Active: agent-graph, task-graph, message-graph, thought-graph, report-graph, swarm-graph, coordinator-graph
```

### 5. Bootstrap the Seed Agent

The seed agent is generation 0 — it spawns planner-001 and starts the self-sustaining loop.

```bash
kubectl apply -f manifests/bootstrap/seed-agent.yaml
```

Watch the seed agent:
```bash
kubectl logs -f jobs/bootstrap-seed -n agentex
```

The seed will:
1. Verify RGD health
2. Spawn worker agents for top 3 open issues
3. Spawn planner-001 (the civilization heartbeat)
4. Post a bootstrap completion GitHub Issue

### 6. Verify the Civilization is Running

Check that agents are spawning and working:

```bash
# Active jobs (should see planner-XXX and worker-XXX)
kubectl get jobs -n agentex | grep Running

# Agent CRs created by kro
kubectl get agents.kro.run -n agentex

# Recent thought CRs (agent communication)
kubectl get thoughts.kro.run -n agentex -o custom-columns=TIME:.metadata.creationTimestamp,AGENT:.spec.agentRef,TYPE:.spec.thoughtType

# Check GitHub for new issues filed by agents
gh issue list --repo YOUR_ORG/YOUR_REPO --state open --limit 10
```

### 7. Monitor Health

Check circuit breaker status (prevents proliferation):
```bash
kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.circuitBreakerLimit}'
kubectl get jobs -n agentex --no-headers | grep Running | wc -l
```

Active jobs should stay below circuit breaker limit (default: 6).

Check kill switch (emergency stop):
```bash
kubectl get configmap agentex-killswitch -n agentex -o jsonpath='{.data.enabled}'
```

Should be `false` during normal operation.

## Troubleshooting

### Agents not spawning
- Check RGD status: `kubectl describe resourcegraphdefinition agent-graph`
- Verify constitution ConfigMap: `kubectl get configmap agentex-constitution -n agentex -o yaml`
- Check ECR image pull: `kubectl describe pod <agent-pod> -n agentex`

### Agents filing issues on wrong GitHub repo
- Verify `githubRepo` in constitution: `kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.githubRepo}'`
- Check agent env vars: `kubectl get job <agent-job> -n agentex -o jsonpath='{.spec.template.spec.containers[0].env}'`

### S3 errors (memory/chronicle not persisting)
- Check IAM permissions on Pod Identity role
- Verify S3 bucket exists: `aws s3 ls s3://YOUR_BUCKET`
- Check `s3Bucket` in constitution: `kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.s3Bucket}'`

### Circuit breaker triggered (no spawning)
- Active jobs at limit. Wait for jobs to complete, or raise limit:
  ```bash
  kubectl patch configmap agentex-constitution -n agentex --type=merge -p '{"data":{"circuitBreakerLimit":"10"}}'
  ```

## Next Steps

1. **Define your vision**: Edit `agentex-constitution` ConfigMap `vision` field to set your civilization's goals
2. **File initial issues**: Create GitHub issues for features you want agents to build
3. **Watch the loop**: Agents will continuously audit, plan, implement, and spawn successors
4. **Steer via directives**: Update `lastDirective` in constitution ConfigMap when you want to change priorities

## Reverting to Original (pnz1990/agentex)

If you want to revert changes:

```bash
git checkout manifests/system/constitution.yaml manifests/bootstrap/seed-agent.yaml manifests/system/constitution-validator.yaml
```

Or re-run `install-configure.sh` with original values:
```bash
./install-configure.sh \
  --ecr-registry 569190534191.dkr.ecr.us-west-2.amazonaws.com \
  --aws-region us-west-2 \
  --cluster-name agentex \
  --github-repo pnz1990/agentex \
  --s3-bucket agentex-thoughts
```

## Support

For issues with agentex installation or portability:
- File an issue: https://github.com/pnz1990/agentex/issues
- Label: `enhancement`, `portability`
