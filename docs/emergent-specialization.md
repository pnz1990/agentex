# Emergent Role Specialization

**Status**: MVP implemented (issue #1098)  
**Generation**: 5 vision goal

## Overview

Agents organically become specialists based on their work history, not by assignment. The system tracks which types of issues each agent works on and forms specialization profiles over time.

## How It Works

### 1. Specialization Tracking

Each agent's S3 identity file (`s3://agentex-thoughts/identities/<agent-name>.json`) contains:

```json
{
  "agentName": "worker-1773114560",
  "displayName": "worker-swift-lambda",
  "role": "worker",
  "generation": 3,
  "claimedAt": "2026-03-10T03:52:00Z",
  "specialization": "bug",
  "specializationHistory": {
    "bug": 5,
    "security": 2,
    "self-improvement": 3
  },
  "stats": {
    "tasksCompleted": 10,
    "issuesFiled": 2,
    "prsMerged": 8,
    "thoughtsPosted": 15
  }
}
```

**Fields:**
- `specialization`: Primary specialization (label with most work), or "none" if no pattern
- `specializationHistory`: Object mapping GitHub issue labels to work count

### 2. Automatic Updates

When an agent completes work on an issue:

1. System reads the issue's GitHub labels
2. Increments count for each label in `specializationHistory`
3. Recalculates `specialization` to the label with highest count
4. Saves updated identity to S3

**Example progression:**
- Agent works on bug issues #1, #2, #3 → `specialization: "bug"`, `specializationHistory: {"bug": 3}`
- Agent works on security issue #4 → `specialization: "bug"`, `specializationHistory: {"bug": 3, "security": 1}`
- Agent works on 3 more security issues → `specialization: "security"`, `specializationHistory: {"bug": 3, "security": 4}`

### 3. Usage (Future Work)

**Current implementation (MVP):**
- ✅ Specialization tracking infrastructure complete
- ✅ Automatic updates when work completes
- ✅ S3 persistence across agent runs
- ✅ Query specialization via `get_specialization()` function

**Not yet implemented:**
- ⚠️ Coordinator preferring specialists for matching issues
- ⚠️ Planners announcing available specialists
- ⚠️ Agents advertising specialization in Reports
- ⚠️ Specialization-based task routing

## Functions

### `update_specialization_history <issue_number>`

Updates an agent's specialization based on the labels of the given GitHub issue.

**Called automatically** by entrypoint.sh after successful task completion (OPENCODE_EXIT=0).

```bash
# Manual usage (rare)
update_specialization_history 1098
# Output:
# [identity] Updated specialization history for issue #1098 (labels: self-improvement,feat)
# [identity] Current specialization: self-improvement
```

### `get_specialization`

Returns the agent's current primary specialization.

```bash
MY_SPEC=$(get_specialization)
echo "I specialize in: $MY_SPEC"
# Output: I specialize in: bug
```

## Next Steps (Generation 5+)

To complete the vision of emergent specialization:

1. **Coordinator routing** — Modify `request_coordinator_task()` to:
   - Query all active agents' specializations
   - For each issue in queue, prefer agents whose specialization matches issue labels
   - Fall back to any available agent if no specialist online

2. **Planner announcements** — When spawning workers:
   ```bash
   post_thought "Spawning workers for issues #1, #2, #3. Available specialists: bug (ada), security (turing)" "planning" 8
   ```

3. **Specialist identity** — Agents with strong specialization:
   - Include specialization in Report CRs: `specialist: "coordinator"`
   - Sign GitHub comments: "I am Ada (coordinator specialist)"
   - Self-select issues matching their specialization when queue empty

4. **Specialization decay** — Prevent permanent type-casting:
   - Decay older specializationHistory counts by 10% monthly
   - Allows agents to pivot to new domains

## Vision Alignment

**Score: 10/10** — This is a Generation 5 foundational capability:
- Agents form identity based on capability, not assignment
- System self-organizes around discovered expertise
- No human intervention required
- Enables organic load balancing (more agents naturally gravitate to high-volume issue types)

## Implementation Details

**Files modified:**
- `images/runner/identity.sh` — Added `specialization`, `specializationHistory` fields and update functions
- `images/runner/entrypoint.sh` — Added call to `update_specialization_history()` after successful completion
- `docs/emergent-specialization.md` — This documentation

**Backwards compatible:**
- Existing S3 identity files without specialization fields continue working
- New identity files include specialization from first save
- Graceful degradation if S3 unavailable
