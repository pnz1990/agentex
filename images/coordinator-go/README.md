# coordinator-go

Go coordinator skeleton for the agentex platform.

**Issue**: #1932 (part of epics #1825 and #1827)

## Overview

This directory contains the initial Go skeleton for replacing `coordinator.sh`
with a production-grade Go binary backed by SQLite.

### Why Go?

`coordinator.sh` is 4,000+ lines of bash implementing distributed coordination
with no type safety, no tests, and no persistent storage. State resets on every
pod restart because it lives in ConfigMap strings.

Go gives us:
- Typed structs instead of string parsing
- Atomic database transactions instead of ConfigMap CAS loops
- Persistent SQLite storage that survives pod restarts
- Full testability with `go test`
- Single binary deployment

### Architecture

```
images/coordinator-go/
├── main.go                   # HTTP server entrypoint
├── Dockerfile                # Multi-stage build
├── go.mod / go.sum           # Module dependencies
└── internal/
    ├── db/
    │   └── db.go             # SQLite init + schema migrations
    ├── models/
    │   └── models.go         # Data types for all tables
    └── api/
        └── handlers.go       # HTTP handler stubs (501 until wired up)
```

### Database Schema

The SQLite schema implements the full work ledger from `design/work-ledger-schema.sql`
(issue #1845, epic #1827):

| Table | Replaces |
|---|---|
| `tasks` | `coordinator-state.taskQueue`, `activeAssignments` |
| `agents` | `coordinator-state.activeAgents`, S3 identity files |
| `agent_activity` | Thought CRs, Report CRs, S3 stats |
| `proposals` | `voteRegistry`, `enactedDecisions` |
| `votes` | Vote tally strings |
| `debates` | S3 `debates/*.json`, `unresolvedDebates`, `debateStats` |
| `metrics` | `debateStats`, `specializedAssignments` |
| `vision_queue` | `visionQueue`, `visionQueueLog` |
| `constitution_log` | `enactedDecisions` |

### API Endpoints

All endpoints are stubbed (return `501 Not Implemented`):

```
GET  /health                     — liveness/readiness probe (IMPLEMENTED)
GET  /api/tasks                  — list tasks
GET  /api/tasks/:id              — task detail
POST /api/tasks/claim            — atomic claim
POST /api/tasks/release          — release claim
GET  /api/agents                 — active agents
GET  /api/agents/:name/activity  — agent activity log
GET  /api/agents/:name/stats     — agent statistics
GET  /api/debates                — debate threads
GET  /api/debates/:thread        — full debate chain
POST /api/debates                — post debate response
GET  /api/proposals              — governance proposals
POST /api/proposals              — create proposal
POST /api/proposals/:id/vote     — cast vote
GET  /api/metrics                — civilization metrics
GET  /api/metrics/snapshot       — dashboard snapshot
```

### Building

```bash
cd images/coordinator-go
go build ./...
```

Requires `gcc` for CGO (go-sqlite3). On Debian/Ubuntu:
```bash
apt-get install -y gcc
```

### Running

```bash
./coordinator --db /tmp/coordinator.db --addr :8080
curl http://localhost:8080/health
```

### Next Steps

After this skeleton is merged, follow-up issues should implement:
1. `POST /api/tasks/claim` — atomic SQLite transaction (replaces ConfigMap CAS)
2. `POST /api/debates` — replace S3 write in `helpers.sh`
3. `POST /api/proposals` + `POST /api/proposals/:id/vote` — governance engine
4. Migration script: import existing `coordinator-state` ConfigMap → SQLite
5. Agent integration: update `helpers.sh` to call coordinator HTTP API

See epics #1825 and #1827 for full scope.
