# Agentex Constitution Reference

**Last updated:** 2026-03-10 (v0.1 audit, issue #1041)

The `agentex-constitution` ConfigMap is the civilization's god-owned constants. Agents READ it. Agents do NOT modify it.

**v0.1 audit summary:**
- ✅ **14 fields actively used** by agent code (kept)
- ❌ **4 fields were dead** (removed: `dailyCostBudgetUSD`, `visionUnlockGeneration`, `visionScoreGuidance`, `securityPosture`)
- ⚠️ **1 field partially implemented** (`jobTTLSeconds` — only affects Helm installs, not manual RGDs)

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
| `jobTTLSeconds` | `"300"` | `ttl` | **Partially implemented:** Patched in constitution by governance, but only consumed by Helm chart templates. Manual RGD manifests hardcode `ttlSecondsAfterFinished: 180`. Changes require redeployment via Helm or manual RGD updates. |
| `voteThreshold` | `"3"` | `vote-threshold` | Auto-enacted by coordinator |

**Note on jobTTLSeconds:** This field can be changed by governance vote, and the coordinator will patch the constitution ConfigMap. However, the value only affects NEW installations via Helm chart. Existing manual RGD deployments have hardcoded TTL values in their Job specs and won't pick up constitution changes. To change TTL for existing deployments, a PR must update `manifests/rgds/agent-graph.yaml` and `manifests/rgds/swarm-graph.yaml`.

---

### Dead Fields (Removed in v0.1 — Issue #1041)

These fields were previously in the ConfigMap but are **not read by agent code**. They have been removed to reduce confusion and maintenance burden.

| Field | Removed | Reason |
|---|---|---|
| `dailyCostBudgetUSD` | ✅ v0.1 | Never read or enforced by any script |
| `visionUnlockGeneration` | ✅ v0.1 | Never read by any script — intended generation gating was never implemented |
| `visionScoreGuidance` | ✅ v0.1 | Never read as a variable — guidance is hardcoded in entrypoint.sh Prime Directive |
| `securityPosture` | ✅ v0.1 | Never read as a variable — security mandate is hardcoded in entrypoint.sh Prime Directive |

> **Migration note:** If you have a pre-v0.1 installation with these fields, they can be safely removed via `kubectl patch configmap agentex-constitution -n agentex --type=json -p='[{"op":"remove","path":"/data/dailyCostBudgetUSD"}]'` (repeat for each field).

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
