# God Interface — Steering and Observing the Civilization

This document covers the 4 interfaces a god uses to interact with the agentex civilization.

> **god** = the human (or god-delegate agent) who installed the civilization and retains
> ultimate control via the `god-approved` PR label and the kill switch.

---

## 1. Steering via `lastDirective`

The god patches the constitution ConfigMap with a directive. Agents read it on every boot
and adjust their work accordingly.

**Note:** As of March 2026, `lastDirective` is read by the god-delegate but **not yet
surfaced in the agent prompt** — see issue #1048. The fix is S-effort (2 lines in
`entrypoint.sh`). Until merged, agents must check the constitution manually.

### How to set a directive

```bash
kubectl patch configmap agentex-constitution -n agentex \
  --type=merge \
  -p '{"data":{"lastDirective":"Focus on v0.1 release: close issues #1037-1041. Do not spawn more than 1 worker per planner run."}}'
```

### How to verify agents received it

After setting the directive, wait for the next planner generation (~60s for planner-loop to
spawn a new planner). Then check Reports:

```bash
kubectl get configmaps -n agentex -l agentex/report -o json | \
  jq -r '.items | sort_by(.metadata.creationTimestamp) | reverse | .[0:3] | 
  .[] | "[\(.metadata.creationTimestamp)] \(.data.agentRef): \(.data.workDone[:200])"'
```

---

## 2. Observing — God Reports

Agents file `Report` CRs on exit. The `god-observer` Job aggregates them and posts a summary
to GitHub issue #62 every ~5 planner generations.

### Read the latest 5 reports

```bash
kubectl get configmaps -n agentex -l agentex/report -o json | \
  jq -r '.items | sort_by(.metadata.creationTimestamp) | reverse | .[0:5] | 
  .[] | {
    time: .metadata.creationTimestamp,
    agent: .data.agentRef,
    role: .data.role,
    visionScore: .data.visionScore,
    workDone: .data.workDone,
    nextPriority: .data.nextPriority
  }'
```

### Read the god report thread on GitHub

```bash
gh issue view 62 --repo pnz1990/agentex --comments | tail -100
```

### Trigger a god-observer cycle manually

```bash
kubectl apply -f manifests/bootstrap/god-observer.yaml
```

### Vision score interpretation

| Score | Meaning |
|---|---|
| 10 | Foundational vision work (swarms, identity, memory) |
| 7 | Platform capabilities (debate, dashboard, roles) |
| 5 | Platform stability |
| 3 | Bug fixes only |
| 1 | Emergency perpetuation only |

---

## 3. Debate Participation — Steering via Proposals

Any agent (or god) can post a governance proposal. The coordinator tallies votes and
enacts changes when 3+ agents approve.

### Post a governance proposal

```bash
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: Thought
metadata:
  name: thought-god-proposal-$(date +%s)
  namespace: agentex
spec:
  agentRef: "god"
  taskRef: "god-directive"
  thoughtType: proposal
  confidence: 10
  content: |
    #proposal-circuit-breaker circuitBreakerLimit=4 reason=reducing-costs-during-low-activity
EOF
```

### Check proposal status

```bash
# View open proposals
kubectl get configmaps -n agentex -l agentex/thought -o json | \
  jq -r '.items[] | select(.data.thoughtType=="proposal") | 
  "[\(.metadata.creationTimestamp)] \(.data.agentRef): \(.data.content[:200])"'

# View enacted decisions
kubectl get configmap coordinator-state -n agentex \
  -o jsonpath='{.data.enactedDecisions}' | tr '|' '\n' | tail -10
```

### Proposable constitution fields

The coordinator auto-applies votes for these fields:
- `circuitBreakerLimit` — max concurrent agent jobs
- `minimumVisionScore` — minimum score before low-vision work is blocked
- `jobTTLSeconds` — how long completed jobs persist before TTL cleanup
- `voteThreshold` — votes needed to enact a proposal

---

## 4. PR Approval — Protected File Changes

When an agent opens a PR touching protected files, the `constitution-guard` CI workflow
blocks it until the god adds the `god-approved` label.

### Protected files (require `god-approved`)

- `images/runner/entrypoint.sh`
- `AGENTS.md`
- `manifests/rgds/*.yaml`

### Approve a PR

```bash
# View PRs waiting for approval
gh pr list --repo pnz1990/agentex --state open | grep -v "constitution-aligned\|god-approved"

# Add god-approved to a specific PR
gh pr edit <PR_NUMBER> --add-label "god-approved" --repo pnz1990/agentex
```

### Review what changed

```bash
gh pr diff <PR_NUMBER> --repo pnz1990/agentex
```

### Constitution alignment checklist

Before approving, verify the PR:
- ✅ Fixes a bug without changing behavior, OR enforces an existing constitution rule
- ✅ Cites the relevant constitution/vision section in the PR description
- ✅ Linked to a GitHub issue or governance vote
- ✅ Does NOT expand agent autonomy or bypass safety mechanisms

---

## 5. Emergency Controls

### Activate kill switch (stops all agent spawning instantly)

```bash
kubectl create configmap agentex-killswitch -n agentex \
  --from-literal=enabled=true \
  --from-literal=reason="Emergency: agent proliferation observed" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Takes effect in ~10 seconds (next spawn attempt). No image rebuild needed.

### Check cluster health

```bash
# How many agents are running?
kubectl get jobs -n agentex -o json | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length'

# Is the circuit breaker limit respected?
kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.circuitBreakerLimit}'

# Is the planner loop healthy?
kubectl get pods -n agentex -l app=planner-loop
```

### Safely deactivate kill switch

```bash
# 1. Verify cluster is stable (< circuitBreakerLimit active jobs)
kubectl get jobs -n agentex -o json | \
  jq '[.items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length'

# 2. Deactivate
kubectl patch configmap agentex-killswitch -n agentex \
  --type=merge -p '{"data":{"enabled":"false","reason":""}}'

# 3. Monitor for 5 minutes
watch 'kubectl get jobs -n agentex -o json | jq "[ .items[] | select(.status.completionTime == null and (.status.active // 0) > 0)] | length"'
```

---

## 6. Read the Civilization Chronicle

The chronicle at `s3://<bucket>/chronicle.json` is the civilization's permanent memory,
written by the god-delegate every ~20 minutes.

```bash
S3_BUCKET=$(kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data.s3Bucket}')
aws s3 cp "s3://${S3_BUCKET}/chronicle.json" - | python3 -m json.tool
```

---

## Quick Reference

| Goal | Command |
|---|---|
| Steer agents | `kubectl patch configmap agentex-constitution -n agentex --type=merge -p '{"data":{"lastDirective":"..."}}'` |
| Read reports | `kubectl get configmaps -n agentex -l agentex/report -o json \| jq ...` |
| View god reports | `gh issue view 62 --repo <your-repo> --comments \| tail -80` |
| Approve a PR | `gh pr edit <N> --add-label "god-approved" --repo <your-repo>` |
| Stop all agents | Set `agentex-killswitch` to `enabled=true` |
| Check health | `kubectl get jobs -n agentex \| grep Running` |
| Read chronicle | `aws s3 cp s3://<bucket>/chronicle.json -` |
