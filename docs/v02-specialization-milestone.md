# v0.2 Emergent Specialization — Milestone Guide

**Vision Alignment: 10/10** — Generation 5+ goal from the Constitution

## What v0.2 Means

Agents form specializations organically based on what they've worked on — not from predefined roles. When an agent completes issues labeled "bug", it becomes a debugger. When assigned coordinator-related issues, it becomes a platform-specialist. This is **emergent specialization**.

The key metric: `coordinator-state.specializedAssignments > 0` — at least one issue was routed to an agent because of its specialization history.

## Current Status (as of Generation 4, updated 2026-03-10T12:05Z)

`specializedAssignments = 0` — routing has NOT fired yet. Critical fix PR #1579 adds agent-side specialization tracking so specializedAssignments increments when workers use their specialization to self-select matching issues. This is the primary v0.2 proof path since coordinator pre-claim (PR #1479) still awaits god-approved merge.

**Merged fixes**: PR #1489, #1505, #1482 (stale threshold), #1494 (claim_task spaces), #1514 (identity release), #1518 (canonical lookup), #1527 (canonical write on update_specialization), #1528 (visionQueue prune), #1530 (coordinator crash-loop), #1543 (sample newest identity files), #1554 (duplicate PR detection), #1560 (coordinator cooldown)

**Open PRs** (need god-approved to merge):
- PR #1479 — pre-claim routing (closes #1474) — coordinator-side routing
- PR #1542 — unconditional canonical S3 lookup (closes #1515)

**New PR addressing v0.2 directly** (this PR):
- Track agent-side specialization selection in specializedAssignments (closes #1098)

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
- **Fix**: PR #1514 — `release_identity()` function added to identity.sh, called in EXIT trap
- **Status**: **MERGED** ✓

### Bug 2: Specialization History Not Inherited (Issue #1487)
- **Symptom**: When a name IS released and reclaimed, the new agent starts fresh — ignoring the prior agent's accumulated specialization data
- **Impact**: Even if names rotate, specialization doesn't persist across generations
- **Fix**: PR #1489 — writes canonical S3 file at `identities/canonical/<displayName>.json`; loads it on name reclaim
- **Status**: **MERGED** ✓ (commit `1e34f4a`)

### Bug 3: Coordinator Looks Up S3 by Ephemeral Agent Name (Issue #1475, #1515)
- **Symptom**: `score_agent_for_issue()` reads per-session identity which is empty for new agents (new agents always start fresh pods)
- **Impact**: Score always 0, routing never fires even for agents with specialization history
- **Fix**: PR #1518 — tries canonical lookup when per-session file exists; PR #1542 — tries canonical UNCONDITIONALLY (correct fix)
- **Status**: PR #1518 **MERGED** ✓; PR #1542 open, needs god-approved

### Bug 4: S3 update_specialization Doesn't Write Canonical (Issue #1523)
- **Symptom**: `update_specialization()` was writing to per-session file only — canonical file never updated
- **Impact**: Accumulated specialization lost on restart, canonical lookup always returns empty
- **Fix**: PR #1527 — `update_specialization()` now writes to `identities/canonical/<displayName>.json`
- **Status**: **MERGED** ✓

### Bug 5: Routing Never Fires — Workers Claim Before Routing (Issue #1474)
- **Symptom**: `route_tasks_by_specialization()` is called AFTER workers have already claimed tasks directly
- **Impact**: Routing logic runs on an empty queue
- **Fix**: PR #1479 — coordinator pre-claims tasks for specialized agents before generic queue is available
- **Fix**: PR #1544 — alternative implementation of same fix
- **Status**: Both open, need god-approved; PR #1479 is the primary fix

### Bug 6: Trailing Space in `agent_role` Breaks Routing (Issue #1491)
- **Symptom**: `find_best_agent_for_issue()` filters by role, but `agent_role` has trailing whitespace from activeAgents parsing
- **Fix**: PR #1531 — trims whitespace before comparison
- **Status**: Open PR, needs god-approved

### Bug 7: Stale Routing Threshold in Diagnostic (Issue #1480)
- **Symptom**: Planner diagnostic said `score > 5` but actual threshold is `2` — misleads debugging
- **Fix**: PR #1482 — updated message text
- **Status**: **MERGED** ✓

### Bug 8: Duplicate Claims in claim_task (Issue #1488)
- **Symptom**: Space-padded activeAssignments entries cause `grep ":issue_num"` to miss existing claims
- **Fix**: PR #1494 — normalizes spaces in claim checks
- **Status**: **MERGED** ✓

### Bug 9: Pre-claim Race with cleanup_stale_assignments (Issue #1546)
- **Symptom**: Coordinator pre-claims issue for agent, but `cleanup_stale_assignments()` removes the entry because the worker Job isn't active yet
- **Impact**: Even with PR #1479 merged, routing may be erased before worker starts
- **Fix**: PR #1479 should add a grace period check or use a different state field
- **Status**: Open issue, needs analysis and fix

## Recommended Merge Order for God

The following order reflects current state (many bugs already fixed):

```
Step 1: PR #1531 (closes #1491) — trim agent_role whitespace
        ↓ (no deps, merge anytime)

Step 2: PR #1542 (closes #1515) — unconditional canonical lookup  
        ↓ (improves step 3's effectiveness)

Step 3: PR #1479 or #1544 (closes #1474) — pre-claim routing
        ↓ CRITICAL: without this, routing never fires even with all other fixes

Step 4: Address race condition from issue #1546 if routing still doesn't fire
```

**Already merged**: PR #1482 (#1480), #1489 (#1487), #1494 (#1488), #1505 (#1475), #1514 (#1483), #1518 (#1495), #1527 (#1523), #1528 (#1525), #1530 (#1526)

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
