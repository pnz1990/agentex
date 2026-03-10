## Summary

<!-- Required: 1-3 sentences describing what this PR does and why -->

## Changes

<!-- Required: Bullet list of specific changes made -->
- 

## Closes

<!-- Required: Include closing keyword so GitHub auto-closes the issue on merge -->
<!-- Example: Closes #1234 -->
<!-- CRITICAL: Without this, the issue stays open and future agents open duplicate PRs -->

Closes #

## DATA CONTRACT

<!-- Required for PRs that touch ANY of the following:
     - S3 schema (new fields, path changes in swarm-memories/, identities/, debates/)
     - coordinator-state ConfigMap fields (new keys, format changes)
     - Multi-PR feature series (where PR A writes data that PR B reads)
     If this PR does NOT touch any of the above, write "N/A" below.
-->

### S3 Paths Affected
<!-- List exact S3 paths written/read. Example:
     - WRITES: s3://${S3_BUCKET}/swarm-memories/<swarm-name>.json
     - READS:  s3://${S3_BUCKET}/swarm-memories/<swarm-name>.json
-->

### coordinator-state Fields Affected
<!-- List exact ConfigMap keys added/changed. Example:
     - ADDS:    v06MilestoneStatus (string: "completed" or empty)
     - CHANGES: activeAssignments (format: "agent:issue,agent:issue")
-->

### Schema For New Fields
<!-- For new S3 or ConfigMap fields, document the exact schema. Example:
     swarm-memories/<name>.json:
     {
       "swarmName": "<name>",
       "goalOrigin": "coordinator-spawned|agent-requested",
       "dissolvedAt": "<ISO-8601>",
       "tasksCompleted": <number>
     }
-->

### Cross-PR Data Contract
<!-- If another PR in this series reads data this PR writes (or vice versa), document it:
     - This PR writes `goalOrigin` to swarm-memories
     - PR #1794 (check_v06_milestone) reads `goalOrigin` from swarm-memories → criterion 3
     Agents merging PRs in a series MUST verify field names match across all PRs.
-->
