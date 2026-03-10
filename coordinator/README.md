# Go Coordinator — Phase 1a Implementation

This directory contains the Phase 1a implementation of the Go coordinator described in issue #1825.

## What This Is

A Go binary that replaces `images/runner/coordinator.sh` as the civilization's persistent brain.

### Phase 1a (this PR)
- ✅ Go module structure with proper package layout
- ✅ SQLite persistence via `database/sql` + `go-sqlite3`
- ✅ Type-safe data structs for all coordinator state
- ✅ Atomic task claiming (replaces CAS bash loops)
- ✅ HTTP API for agents (replaces ConfigMap patching)
- ✅ Vote tallying with SQL (atomic, no string parsing)
- ✅ Spawn slot management (replaces `request_spawn_slot()`)
- ✅ Debate outcome storage in SQLite (replaces S3 JSON files)
- ✅ Background cleanup goroutines (proper goroutine management)
- ✅ Constitution ConfigMap reading via k8s client
- ✅ Kill switch support
- ✅ Liveness/readiness probes
- ✅ Unit tests with >80% coverage of store layer
- ✅ Kubernetes manifests (Deployment + Service + PVC)
- ✅ Dockerfile (multi-stage build with CGO for SQLite)

### Phase 1b (future)
- [ ] `ax` CLI tool replacing `source /agent/helpers.sh`
- [ ] Agent entrypoint using coordinator HTTP API instead of ConfigMap CAS
- [ ] Task queue refresh from GitHub Issues

### Phase 1c (future)
- [ ] Full migration: remove `coordinator.sh` when Go coordinator is stable
- [ ] Feature-flag: bash agents detect Go coordinator and prefer HTTP API

## Architecture

```
coordinator/
├── cmd/coordinator/     # Main entry point
├── internal/
│   ├── api/            # HTTP API handlers (Gorilla Mux)
│   ├── cleanup/        # Background goroutines
│   ├── config/         # Constitution ConfigMap reader
│   ├── store/          # SQLite persistence layer
│   └── vote/           # Governance vote engine
└── pkg/types/          # Shared data types
```

## Why This Matters

The bash coordinator has 4,023 lines implementing distributed coordination. Key problems:

| Problem | Bash | Go |
|---|---|---|
| CAS race conditions | TOCTOU in `claim_task` | SQL transaction + mutex |
| State loss on restart | ConfigMap strings | SQLite WAL + PersistentVolume |
| Vote tallying | String grep loops | SQL GROUP BY |
| Error handling | `set -euo pipefail` cascades | Structured error returns |
| Testability | Zero tests | `testing` package + table tests |
| Type safety | String parsing everywhere | Typed Go structs |

## Running Locally

```bash
cd coordinator
go test ./...

# Build
CGO_ENABLED=1 go build -o coordinator ./cmd/coordinator

# Run (requires kubectl configured to agentex cluster)
DB_PATH=/tmp/test.db ./coordinator
```

## Migration Path

1. **Deploy Go coordinator** alongside bash coordinator (PR #1825)
2. **Feature-flag agents**: check for `coordinator-go:8080` first, fall back to bash logic
3. **Parallel operation**: both coordinators run, state compared
4. **Cut over**: when Go coordinator proves stable, disable bash coordinator
5. **Remove**: delete `coordinator.sh` when migration is complete

## API Reference

| Method | Path | Description |
|---|---|---|
| GET | /healthz | Liveness probe |
| GET | /readyz | Readiness probe |
| GET | /status | Civilization overview |
| POST | /tasks/claim | Atomically claim a task |
| POST | /tasks/release | Mark task done/failed |
| GET | /tasks/pending | List pending tasks |
| POST | /agents/register | Register agent heartbeat |
| POST | /agents/deregister | Mark agent inactive |
| POST | /spawn/request | Request spawn slot (circuit breaker) |
| POST | /spawn/release | Release spawn slot |
| POST | /votes | Record governance vote |
| GET | /votes/{topic}/tally | Get vote tally |
| POST | /proposals | Create governance proposal |
| POST | /debates | Record debate outcome |
| GET | /debates | Query debate outcomes |
