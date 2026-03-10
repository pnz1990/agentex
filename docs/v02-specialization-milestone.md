# v0.2 Emergent Specialization — Milestone Guide

**Vision Alignment: 10/10** — Generation 5+ goal from the Constitution

## What v0.2 Means

Agents form specializations organically based on what they've worked on — not from predefined roles. When an agent completes issues labeled "bug", it becomes a debugger. When assigned coordinator-related issues, it becomes a platform-specialist. This is **emergent specialization**.

The key metric: `coordinator-state.specializedAssignments > 0` — at least one issue was routed to an agent because of its specialization history.

## Current Status (as of Generation 4)

`specializedAssignments = 0` — routing has NOT fired yet. Multiple issues blocking the pipeline have been identified and are being fixed.

## The Bug Chain

v0.2 requires these components to all work together:

```
Agent completes issue → update_specialization() → S3 canonical file
                                                        ↓
Coordinator finds active agents → score_agent_for_issue() → reads S3
                                                        ↓
If score > ROUTING_THRESHOLD → pre-claims issue for that agent
                                                        ↓
specializedAssignments++ → v0.2 VALIDATED ✓
```

Each step has had bugs. Here is the complete bug chain identified in Generation 4:

### Bug 1: Name Registry Never Releases Names (Issue #1483)
- **Symptom**: All 12 worker name slots permanently claimed — workers always get generated names like `worker-bold-tensor` with empty specialization history
- **Impact**: Without persistent names, specialization data never accumulates
- **Fix**: PR #1486 — releases names back to registry on agent completion
- **Status**: Open PR, needs god-approved merge

### Bug 2: Specialization History Not Inherited (Issue #1487)
- **Symptom**: When a name IS released and reclaimed, the new agent starts fresh — ignoring the prior agent's accumulated specialization data
- **Impact**: Even if names rotate, specialization doesn't persist across generations
- **Fix**: PR #1489 — writes canonical S3 file at `identities/canonical/<displayName>.json`; loads it on name reclaim
- **Status**: **MERGED** ✓ (commit `1e34f4a`)

### Bug 3: Coordinator Looks Up S3 by Ephemeral Agent Name (Issue #1475)
- **Symptom**: `score_agent_for_issue()` reads `identities/<agent_name>.json` but history accumulates under `identities/<agent_name>.json` (per-session) or `identities/canonical/<displayName>.json` (canonical)
- **Impact**: Score always 0, routing never fires
- **Fix**: PR #1484 — passes `displayName` as 5th argument to `score_agent_for_issue()`, looks up by displayName first
- **Status**: Open PR, needs god-approved merge

### Bug 4: S3 Path Mismatch — PR #1484 vs PR #1489 (Issue #1495)
- **Symptom**: PR #1484 reads `identities/<displayName>.json` but PR #1489 writes `identities/canonical/<displayName>.json`
- **Impact**: Even after both PRs merge, coordinator can't find the canonical history
- **Fix**: Being implemented (issue #1495) — add fallback to check `identities/canonical/<displayName>.json`
- **Status**: Being worked on by active agents

### Bug 5: Routing Never Fires — Workers Claim Before Routing (Issue #1474)
- **Symptom**: `route_tasks_by_specialization()` is called AFTER workers have already claimed tasks directly
- **Impact**: Routing logic runs on an empty queue
- **Fix**: PR #1479 — coordinator pre-claims tasks for specialized agents before generic queue is available
- **Status**: Open PR, needs god-approved merge

### Bug 6: Trailing Space in `agent_role` Breaks Routing (Issue #1491)
- **Symptom**: `find_best_agent_for_issue()` filters by role, but `agent_role` has trailing whitespace from activeAgents parsing
- **Fix**: PR #1493 — trims whitespace before comparison
- **Status**: Open PR

### Bug 7: Stale Routing Threshold in Diagnostic (Issue #1480)
- **Symptom**: Planner diagnostic says `score > 5` but actual threshold is `2` — misleads debugging
- **Fix**: PR #1482 — updates message text only
- **Status**: Open PR

### Bug 8: Duplicate Claims in claim_task (Issue #1488)
- **Symptom**: Space-padded activeAssignments entries cause `grep ":issue_num"` to miss existing claims
- **Fix**: PR #1494 — normalizes spaces in claim checks
- **Status**: Open PR

## Recommended Merge Order for God

The following order minimizes conflicts and respects dependencies:

```
Step 1: PR #1494 (closes #1488) — normalize claim_task spaces
        ↓ (no deps, merge anytime)

Step 2: PR #1493 (closes #1491) — trim agent_role whitespace
        ↓ (no deps, merge anytime)

Step 3: PR #1482 (closes #1480) — fix stale diagnostic message
        ↓ (no deps, merge anytime)

Step 4: PR #1486 (closes #1483) — release names back to registry
        ↓ MUST merge before #1479 and #1495 fix

Step 5: PR #1484 (closes #1475) — displayName-based identity lookup
        + PR #1495-fix (closes #1495) — add canonical path fallback
        ↓ (these two should be coordinated — #1495 fix extends #1484)

Step 6: PR #1479 (closes #1474) — pre-claim routing for specialized agents
        ↓ MERGE LAST: requires agents with specialization data (steps 4-5)
```

**Note**: PR #1492 was closed without merge (duplicate of #1484). PR #1489 is already merged.

## Validation Checklist

After all PRs merge and a new image deploys:

```bash
# 1. Verify names rotate (should be < 15 "claimed" entries)
kubectl get configmap agentex-name-registry -n agentex -o jsonpath='{.data}' | \
  grep -o "claimed" | wc -l

# 2. Verify canonical S3 files exist for workers
aws s3 ls s3://agentex-thoughts/identities/canonical/ | head -5

# 3. Monitor specializedAssignments after several worker generations
kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.specializedAssignments}'
# Should be > 0 within 2-3 worker generations

# 4. Check routing decisions
kubectl get configmap coordinator-state -n agentex -o jsonpath='{.data.lastRoutingDecisions}'
```

## Related Issues

- #1474, #1475, #1480, #1483, #1487, #1488, #1491, #1495 — all v0.2 bugs
- #1098 — original emergent specialization issue (Generation 5 goal)
- #1113 — specialization tracking improvements

## What Comes Next (v0.3)

Once `specializedAssignments > 0` is confirmed:

- **Issue #1149** — visionQueue self-population (agents collectively set civilization goals)
- **Issue #1219** — agent collective goal-setting via governance votes
- **Issue #1228** — mentorship chains (experienced agents guide newcomers)
- **Cross-generation knowledge transfer** — agents reasoning about 3-step futures

v0.3 begins when the civilization can **choose its own goals**, not just execute god-assigned tasks.
