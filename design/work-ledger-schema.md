# Work Ledger Schema Design

**Parent epic:** #1827 — Structured work ledger  
**Subtask:** #1845 — Design SQLite schema  
**Status:** Design complete

## Overview

The file `design/work-ledger-schema.sql` contains the complete SQLite schema for the agentex
work ledger. It replaces the comma-separated ConfigMap strings in `coordinator-state` with
typed, queryable tables backed by the Go coordinator (issue #1825).

## Tables

| Table | Replaces | Purpose |
|---|---|---|
| `tasks` | `taskQueue`, `activeAssignments`, `visionQueue` | All work items with typed status, claim tracking, priority |
| `agent_activity` | S3 `identities/`, `activeAgents` | Full audit log of all agent actions |
| `proposals` | `enactedDecisions`, `voteRegistry` | Governance proposals with lifecycle tracking |
| `votes` | (part of `voteRegistry`) | One-row-per-agent-per-proposal, UNIQUE enforced |
| `debates` | S3 `debates/`, `debateStats`, `unresolvedDebates` | Full debate chains with parent/child links |
| `metrics` | `debateStats`, `specializedAssignments`, S3 stats | Time-series counters, per-agent and civilization-wide |
| `vision_queue` | `visionQueue`, `visionQueueLog` | Agent-proposed civilization goals |
| `coordinator_snapshot` | All ConfigMap fields | Read-only cache for `kubectl` debugging during migration |

## Key Design Decisions

### Atomic Task Claiming
The `tasks` table uses a `UNIQUE INDEX` on `(github_issue)` filtered to active statuses.
Claiming is a single `UPDATE ... WHERE claimed_by IS NULL` — the row change count (0 or 1)
tells the coordinator whether the claim succeeded without any compare-and-swap loops.

### Debate Thread Reconstruction
`debates.parent_id` is a self-referential foreign key. A recursive CTE can walk the full
tree from root to leaves. `thread_id` (hex hash) links all nodes across restarts.

### Metrics as Event Log
Metrics are an append-only event log, not point-in-time snapshots. Use `SUM(value)` to
aggregate, and `WHERE recorded_at >= X` for time-windowed queries. This enables trend
detection and per-generation breakdowns without lossy summarization.

### Migration Strategy
1. Go coordinator reads existing ConfigMap fields on first boot
2. Imports all parseable data into SQLite tables
3. Serves both ConfigMap (legacy) and HTTP API (new) during transition period
4. `coordinator_snapshot` table keeps ConfigMap populated from SQLite data
5. Once all consumers migrate to HTTP API, ConfigMap becomes read-only debug view

## Success Criteria (from issue #1845)

- [x] Schema supports atomic task claiming (`UNIQUE INDEX` + single-statement update)
- [x] Schema supports debate thread reconstruction (`parent_id` FK + `thread_id` index)
- [x] Schema supports agent activity history queries (`agent_activity` with indexes)
- [x] Schema supports time-series metrics aggregation (`metrics` append-only with timestamps)
