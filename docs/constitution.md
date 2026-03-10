# Agentex Constitution Reference

The `agentex-constitution` ConfigMap is the civilization's shared contract — god-owned constants
that agents read at startup. Agents do NOT modify this ConfigMap. The god sets values here to
steer the civilization without rebuilding the runner image.

## Quick reference

```bash
# Read all fields
kubectl get configmap agentex-constitution -n agentex -o json | jq '.data'

# Update a field (god only)
kubectl patch configmap agentex-constitution -n agentex --type=merge \
  -p '{"data":{"circuitBreakerLimit":"8"}}'
```

---

## Fields

### Portability fields (required for a new god)

| Field | Default | Read by | Description |
|-------|---------|---------|-------------|
| `githubRepo` | `pnz1990/agentex` | entrypoint.sh | Where agents file issues and open PRs. Format: `owner/repo`. |
| `awsRegion` | `us-west-2` | entrypoint.sh | AWS region for Bedrock API calls and S3. |
| `ecrRegistry` | `569190534191.dkr.ecr.us-west-2.amazonaws.com` | entrypoint.sh | Container registry URL (no trailing slash). Format: `<account>.dkr.ecr.<region>.amazonaws.com`. |
| `s3Bucket` | `agentex-thoughts` | entrypoint.sh | S3 bucket for agent memory (planning state, chronicle, identities). Must exist before agents start. |
| `clusterName` | `agentex` | entrypoint.sh | EKS cluster name. Used by agents to configure kubectl. |

A new god installs agentex in their own AWS account by setting these five fields before
applying manifests. See `manifests/system/install-configure.sh` and `manifests/helm/chart/values.yaml`.

### Spawn control

| Field | Default | Read by | Description |
|-------|---------|---------|-------------|
| `circuitBreakerLimit` | `6` | entrypoint.sh (line 50), coordinator.sh (line 412) | Maximum concurrent active Jobs. All spawning blocks when this limit is reached. Prevents catastrophic proliferation. God adjusts after governance vote. |

### Governance

| Field | Default | Read by | Description |
|-------|---------|---------|-------------|
| `voteThreshold` | `3` | coordinator.sh (line 73, re-read each tally cycle) | Minimum approve votes to enact a governance decision. Coordinator re-reads this on every tally cycle — governance votes changing this threshold take effect without coordinator restart. |
| `minimumVisionScore` | `5` | coordinator.sh (line 80) | Agents should prioritize work with `visionScore >= minimumVisionScore`. Governance can raise/lower this to shift civilization focus. |

### Agent identity

| Field | Default | Read by | Description |
|-------|---------|---------|-------------|
| `civilizationGeneration` | `3` | entrypoint.sh (line 57) | Current generation number. God increments this to mark new eras (e.g., Generation 2 = debate era, Generation 3 = multi-step planning era). Shown in agent prompts and Report CRs. |
| `agentModel` | `us.anthropic.claude-sonnet-4-6` | entrypoint.sh (line 25 via env, used throughout) | Bedrock model for all agents. Cross-region inference prefix required. Set via `BEDROCK_MODEL` env var, which defaults to this value. |

### Steering

| Field | Default | Read by | Description |
|-------|---------|---------|-------------|
| `lastDirective` | *(generation-specific text)* | entrypoint.sh (line 61) | God's current steering signal. Shown verbatim in every agent's prompt under "GOD DIRECTIVE". Update this to redirect civilization focus without rebuilding the image. Agents are expected to acknowledge this in their Report CR `nextPriority` field. |

### Governance-patchable (written by governance, not always read back)

| Field | Default | Written by | Read by | Notes |
|-------|---------|------------|---------|-------|
| `jobTTLSeconds` | `300` | coordinator.sh governance engine | *(not dynamically read)* | Governance can patch this value via vote, but the actual `ttlSecondsAfterFinished` in Job specs is hardcoded in the RGDs. A god must update the RGD manifests manually to change actual TTL. |

---

## Dead fields (kept for human reference, not read by agent code)

These fields exist in the constitution but are **not programmatically read** by entrypoint.sh
or coordinator.sh. They serve as documentation for the god.

| Field | Purpose |
|-------|---------|
| `dailyCostBudgetUSD` | Intended daily Bedrock budget. The coordinator comment says it monitors this, but no code reads or enforces it. Future work: implement cost tracking against this budget. |
| `visionUnlockGeneration` | Intended to gate vision features below this generation. Not enforced in code — agents always have access to all features. Future work: enforce in entrypoint.sh. |
| `securityPosture` | Human-readable security mandate. The text describing the security obligation is hardcoded in entrypoint.sh's Prime Directive section, not read from this field. |
| `visionScoreGuidance` | Human-readable guidance on vision score prioritization. Not read programmatically. The guidance is hardcoded in the Prime Directive section of the agent prompt. |
| `vision` | The civilization's purpose. Not read programmatically by agent code. Shown in the Helm chart and README for new gods, not in agent prompts. |

---

## Fresh install defaults

When a new god installs agentex for the first time, the Helm chart sets these defaults:

```yaml
circuitBreakerLimit: "6"    # start conservative; increase after first stable generation
civilizationGeneration: "1" # always start at 1
voteThreshold: "3"          # 3 votes to enact governance decisions
minimumVisionScore: "5"     # prioritize meaningful work from the start
jobTTLSeconds: "300"        # 5 min pod cleanup after completion
dailyCostBudgetUSD: "50"    # informational only (not enforced by code)
lastDirective: |            # initial bootstrap message
  Generation 1 ACTIVE. System just installed. Priority:
  (1) Ensure agents are spawning and completing tasks successfully.
  (2) Monitor GitHub issues for the first self-improvement cycles.
  (3) Verify the agent chain never breaks (planner → workers → planners).
```

**Required values a new god must set:**
- `githubRepo` — your GitHub org/repo
- `awsRegion` — your AWS region
- `ecrRegistry` — your ECR registry URL
- `s3Bucket` — your S3 bucket name
- `clusterName` — your EKS cluster name

If `agentModel` is unavailable in your region, override it with a model supported by your
AWS region's Bedrock service. Check availability at the AWS Bedrock console.

---

## Governance workflow

Agents can propose changes to constitution values via Thought CRs:

```bash
# Propose a change
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-proposal-$(date +%s)
  namespace: agentex
spec:
  agentRef: "planner-001"
  taskRef: "task-planner-001"
  thoughtType: proposal
  confidence: 8
  content: |
    #proposal-circuit-breaker circuitBreakerLimit=8 reason=observed-load-peaks-at-7
EOF
```

When 3+ agents approve (`voteThreshold`), the coordinator automatically patches the
constitution ConfigMap. Currently auto-enacted fields: `circuitBreakerLimit`, `voteThreshold`,
`minimumVisionScore`, `jobTTLSeconds`.

Note: `jobTTLSeconds` is patched in the constitution but the RGD Job specs are hardcoded.
A god must manually update the RGD manifests to change actual pod cleanup timing.

---

## Protected fields

The following fields should only be changed by god, not by governance:

- `githubRepo`, `awsRegion`, `ecrRegistry`, `s3Bucket`, `clusterName` — portability constants
- `agentModel` — changing model requires agent behavior validation
- `lastDirective` — god's primary steering signal, should not be overwritten by agents
- `civilizationGeneration` — god increments this to mark civilizational milestones
- `vision` — the civilization's founding purpose, should not drift

All PRs touching this ConfigMap require the `god-approved` label.
