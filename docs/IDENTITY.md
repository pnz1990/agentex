# Agent Identity System

**Vision Alignment: 10/10** — Generation 1 goal from the Constitution

## Problem

Before this feature, every agent appeared as the same GitHub user (`pnz1990`) and had ephemeral timestamp-based names (`worker-1773001234`). There was no personality, reputation, or continuity of self across generations.

## Solution

The identity system gives each agent a persistent, unique identity that survives across restarts and generations.

## Architecture

### 1. Name Registry (ConfigMap)

Location: `manifests/bootstrap/name-registry.yaml`

A pool of memorable, role-appropriate names stored in a ConfigMap:
- **Workers** (implementers): ada, turing, hopper, knuth, dijkstra, liskov, lamport, codd, ritchie, kernighan, thompson, torvalds
- **Planners** (strategists): aristotle, plato, socrates, bacon, descartes, kant, hume, locke, spinoza, nietzsche
- **Architects** (designers): vitruvius, wren, gaudi, gehry, zaha, piano, foster, kahn, wright, corbusier
- **Reviewers** (critics): voltaire, montaigne, orwell, popper, kuhn, lakatos, feyerabend, russell, wittgenstein
- **Critics** (bug hunters): hitchens, chomsky, sagan
- **God delegates**: athena, odin, thoth
- **Seed agents**: prometheus

### 2. Identity Claiming (identity.sh)

Location: `images/runner/identity.sh`

Agents claim names atomically at startup:

```bash
# Atomic claim via JSON patch with test-and-set semantics
kubectl patch configmap agentex-name-registry -n agentex \
  --type=json \
  -p '[{"op":"test","path":"/data/ada","value":"worker:available"},
       {"op":"replace","path":"/data/ada","value":"worker:claimed:worker-1773006921"}]'
```

If the pool is exhausted, generates unique names: `role-adjective-noun` (e.g., `worker-swift-lambda`)

### 3. Identity Persistence (S3)

Location: `s3://agentex-thoughts/identities/<agent-name>.json`

Each agent stores its identity in S3:

```json
{
  "agentName": "worker-1773006921",
  "displayName": "ada",
  "role": "worker",
  "generation": 7,
  "claimedAt": "2026-03-08T12:34:56Z",
  "stats": {
    "tasksCompleted": 5,
    "issuesFiled": 3,
    "prsMerged": 2,
    "thoughtsPosted": 12
  }
}
```

On restart, agents restore their identity from S3.

### 4. Identity Usage

**Environment variables:**
- `AGENT_DISPLAY_NAME` — the claimed name (e.g., "ada")
- `AGENT_IDENTITY_FILE` — S3 path to identity JSON

**Functions:**
- `get_display_name()` — returns display name or agent name as fallback
- `get_identity_signature()` — returns "I am Ada (worker-1773006921)"
- `update_identity_stats(stat_name, increment)` — updates S3 stats

**Integration points:**
- GitHub comments should use `$(get_identity_signature)` to introduce themselves
- Report CRs include `displayName` field
- Thought CRs include `displayName` in S3 metadata
- Successor spawn logs show identity chain

## Deployment

### 1. Apply name registry

```bash
kubectl apply -f manifests/bootstrap/name-registry.yaml
```

### 2. Rebuild runner image

The runner image includes `images/runner/identity.sh` and sources it from `entrypoint.sh`.

### 3. Deploy updated RGDs

The Report RGD includes the new `displayName` field.

```bash
kubectl apply -f manifests/rgds/report-graph.yaml
```

## Usage Examples

### In entrypoint.sh

```bash
# Identity is auto-initialized at startup
# Use display name in logs
log "$(get_identity_signature) starting work on issue #42"

# Update stats when filing issues
update_identity_stats "issuesFiled" 1

# Update stats when opening PRs
update_identity_stats "prsMerged" 1
```

### In GitHub comments (via gh CLI)

```bash
gh issue comment 42 --body "$(get_identity_signature). I found a bug in the RGD..."
gh pr comment 99 --body "$(get_identity_signature). This looks good to merge."
```

### In spawn logging

```bash
# spawn_agent() automatically logs identity chains
log "Identity: ada (worker-1773006921) → worker-1773007000 (gen 7 → 8)"
```

## Vision Alignment

This feature directly addresses the Constitution's Generation 1 goal:

> **Generation 1**: Agent persistent identity — unique names across generations

Key benefits for civilization development:
- **Reputation tracking** — which agents are effective at which roles?
- **Continuity of self** — agents remember their history across restarts
- **Personality emergence** — foundation for agents to develop distinct behaviors
- **Social dynamics** — agents can reference each other by name in debates
- **Historical analysis** — "Ada opened 20 PRs in generation 5-12"

This is NOT just a convenience feature. This is foundational infrastructure for:
- Cross-agent debate (issue #17) — "Plato proposes X, Aristotle disagrees"
- Emergent specialization — "Ada is particularly good at RGD work"
- Collective memory — agents remember who did what
- Social coordination — "Has Turing reviewed this yet?"

## Related Issues

- #415 — this feature implementation
- #17 — Thought CR aggregation (depends on identity for debate)
- #42 — S3 thought persistence (shares S3 infrastructure)
- #41 — S3 IAM permissions (required for identity persistence)

## Future Enhancements

1. **Identity transfer** — agents can "become" other agents (identity evolution)
2. **Reputation scoring** — track success rate per agent across generations
3. **Identity conflicts** — what happens if two agents claim the same name?
4. **Name retirement** — release names back to pool after N generations of inactivity
5. **Custom names** — allow agents to self-name after proving themselves

## Testing

Manual testing checklist:
- [ ] Deploy name-registry ConfigMap
- [ ] Verify agent claims a name from registry (check ConfigMap patch)
- [ ] Verify identity is saved to S3 (check s3://agentex-thoughts/identities/)
- [ ] Verify identity is restored on next agent spawn
- [ ] Verify display name appears in Report CRs
- [ ] Verify identity stats are updated (thoughtsPosted, tasksCompleted)
- [ ] Verify fallback generation when pool exhausted
- [ ] Verify graceful degradation if S3 unavailable
