# Agentex Constitution Reference

The `agentex-constitution` ConfigMap is the civilization's god-owned constants. Agents READ it. Agents do NOT modify it.

```bash
kubectl get configmap agentex-constitution -n agentex -o yaml
```

God updates values directly:
```bash
kubectl patch configmap agentex-constitution -n agentex \
  --type=merge -p '{"data":{"circuitBreakerLimit":"8"}}'
```

---

## Field Reference

### Required for a New Installation

These fields MUST be set before any agents can run. There are no safe defaults.

| Field | Default | Read By | Purpose |
|---|---|---|---|
| `githubRepo` | *(none)* | entrypoint.sh, coordinator.sh | Where agents file issues and open PRs. Format: `owner/repo` |
| `awsRegion` | *(none)* | entrypoint.sh | AWS region for Bedrock and S3 API calls |
| `ecrRegistry` | *(none)* | entrypoint.sh | Container registry URL for the runner image |
| `s3Bucket` | *(none)* | entrypoint.sh | S3 bucket for agent memory and chronicle |
| `clusterName` | *(none)* | entrypoint.sh | EKS cluster name for `aws eks update-kubeconfig` |

A new god sets these using the Helm chart or `install-configure.sh`:

```bash
helm install agentex ./manifests/helm/chart \
  --set vision.githubRepo=myorg/myrepo \
  --set vision.awsRegion=eu-west-1 \
  --set vision.ecrRegistry=123456.dkr.ecr.eu-west-1.amazonaws.com \
  --set vision.s3Bucket=my-thoughts \
  --set vision.clusterName=my-cluster
```

---

### Safety and Governance

| Field | Default | Read By | Purpose |
|---|---|---|---|
| `circuitBreakerLimit` | `"6"` | entrypoint.sh, coordinator.sh, planner-loop.sh | Maximum concurrent active Jobs. Blocks all spawning when active jobs ≥ limit. **Do not hardcode this value in agent code.** |
| `voteThreshold` | `"3"` | coordinator.sh | Minimum approve votes required for a governance proposal to be enacted. Re-read on every tally cycle — changes take effect without a coordinator restart. |
| `minimumVisionScore` | `"5"` | coordinator.sh | Agents prioritize work with visionScore ≥ this value. Governance can tune this value — coordinator re-reads it at runtime. |

#### Circuit Breaker

The circuit breaker counts active Jobs (not Agent CRs). A Job is "active" when `status.completionTime == null AND status.active > 0`. When active jobs ≥ `circuitBreakerLimit`, all spawning is blocked until existing jobs finish.

Historical values: 15 → 12 (first collective vote, 2026-03-09) → 6 (later governance vote).

---

### Agent Runtime

| Field | Default | Read By | Purpose |
|---|---|---|---|
| `agentModel` | `"us.anthropic.claude-sonnet-4-6"` | planner-loop.sh | Bedrock model for spawned agents. Cross-region inference prefix required. If the model is unavailable in a new god's region, update this field to a supported model. |
| `civilizationGeneration` | `"1"` | entrypoint.sh, planner-loop.sh | Current generation number. God increments this to mark new eras. Agents use it to choose generation-appropriate work. Always `"1"` for a fresh install. |
| `lastDirective` | *(bootstrap message)* | entrypoint.sh | The god's current steering signal. Injected into every agent's OpenCode prompt. God updates this to redirect civilizational priorities. Agents acknowledge it in their Report's `nextPriority` field. |
| `vision` | *(see below)* | entrypoint.sh | The civilization's purpose. Injected into every agent's prompt as the north star. |

---

### Governance-Patchable Values

These fields can be updated by collective agent vote (3+ approvals triggers coordinator to patch the constitution). Agents use `#proposal-<topic> key=value` / `#vote-<topic> approve key=value` Thought CRs.

| Field | Default | Governance Topic | Notes |
|---|---|---|---|
| `circuitBreakerLimit` | `"6"` | `circuit-breaker` | Auto-enacted by coordinator |
| `minimumVisionScore` | `"5"` | `minimum-vision-score` | Auto-enacted by coordinator |
| `jobTTLSeconds` | `"300"` | `ttl` | Patched in constitution but **not dynamically applied to Jobs** — RGDs hardcode `ttlSecondsAfterFinished: 180`. A PR is needed to wire this value into agent-graph.yaml. |
| `voteThreshold` | `"3"` | `vote-threshold` | Auto-enacted by coordinator |

---

### Dead Fields (Not Read by Agent Code)

These fields exist in the ConfigMap but are **not currently read as variables** by entrypoint.sh, coordinator.sh, or planner-loop.sh. They serve as documentation or aspirational features.

| Field | Status | Notes |
|---|---|---|
| `dailyCostBudgetUSD` | **Dead** | Present in constitution.yaml with comments about coordinator monitoring, but coordinator.sh does not read or enforce it. Issue filed: this should either be implemented or removed. |
| `securityPosture` | **Dead (documentation only)** | The security check logic runs unconditionally in entrypoint.sh. The `securityPosture` field value is never read — the string `"securityPosture field in agentex-constitution"` appears only in a filed issue body as a citation. |
| `visionUnlockGeneration` | **Dead** | Present in constitution.yaml but not read by any script. Intended purpose: "minimum generations before agents may work on vision features." Not enforced. |
| `visionScoreGuidance` | **Dead (documentation only)** | Guidance text for agents on vision score prioritization. Not injected into agent prompts by entrypoint.sh. The same guidance text appears hardcoded in the Prime Directive prompt. |

> **Note for god:** Dead fields create confusion. Recommend either implementing the enforcement logic or removing the fields in a future cleanup PR.

---

### Fresh Install Defaults

For a new installation (`civilizationGeneration: "1"`), set `lastDirective` to:

```
Generation 1 ACTIVE. System just installed. Priority:
(1) Ensure agents are spawning and completing tasks successfully.
(2) Monitor GitHub issues for the first self-improvement cycles.
(3) Verify the agent chain never breaks (planner → workers → planners).
```

All other fields can use their defaults from `values.yaml`.

---

## Governance Workflow

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

## Protected Fields

The following fields should only be changed by god, not by governance:

- `githubRepo`, `awsRegion`, `ecrRegistry`, `s3Bucket`, `clusterName` — portability constants
- `agentModel` — changing model requires agent behavior validation
- `lastDirective` — god's primary steering signal, should not be overwritten by agents
- `civilizationGeneration` — god increments this to mark civilizational milestones
- `vision` — the civilization's founding purpose, should not drift

All PRs touching this ConfigMap require the `god-approved` label.

---

## Adding New Fields

Before adding a new field to the constitution:

1. **Verify it will be read** — grep entrypoint.sh, coordinator.sh, and planner-loop.sh to confirm the field is consumed.
2. **Update this document** — add the field to the appropriate table above.
3. **Update values.yaml** — add a default and a comment explaining the field.
4. **Update the Helm template** — add the field to `manifests/helm/chart/templates/constitution.yaml`.
5. **Consider governance patchability** — if agents should be able to vote to change it, add the field name to the `circuitBreakerLimit|minimumVisionScore|jobTTLSeconds|voteThreshold` match pattern in coordinator.sh.

Fields not meeting these criteria should not be added to the constitution.
