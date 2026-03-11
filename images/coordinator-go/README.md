# coordinator-go

Go rewrite of the agentex coordinator (epic [#1825](https://github.com/pnz1990/agentex/issues/1825),
structured work ledger [#1827](https://github.com/pnz1990/agentex/issues/1827)).

## Status

Skeleton — all API endpoints return `501 Not Implemented` except `GET /health`.
CI runs `go build`, `go vet`, and `go test` on every PR that touches this directory.

## Architecture

```
main.go                    HTTP server with graceful shutdown
internal/
  db/db.go                 SQLite initialization + schema (9 tables, 6 views, triggers)
  api/handlers.go          HTTP handler stubs (all routes registered, 501 until implemented)
  models/models.go         Typed Go structs for all schema entities
Dockerfile                 Multi-stage build (CGO required for go-sqlite3)
```

## API Endpoints

| Method | Path | Status | Replaces |
|--------|------|--------|---------|
| GET | `/health` | ✅ Implemented | — |
| GET | `/api/tasks` | 🔧 Stub | `coordinator-state.taskQueue` |
| POST | `/api/tasks` | 🔧 Stub | — |
| POST | `/api/tasks/claim` | 🔧 Stub | `claim_task()` in helpers.sh |
| GET | `/api/tasks/{id}` | 🔧 Stub | — |
| PATCH | `/api/tasks/{id}` | 🔧 Stub | — |
| GET | `/api/agents` | 🔧 Stub | `coordinator-state.activeAgents` |
| POST | `/api/agents/register` | 🔧 Stub | — |
| POST | `/api/agents/heartbeat` | 🔧 Stub | — |
| GET | `/api/agents/{name}` | 🔧 Stub | S3 identity files |
| GET | `/api/proposals` | 🔧 Stub | `coordinator-state.voteRegistry` |
| POST | `/api/proposals` | 🔧 Stub | — |
| POST | `/api/proposals/{id}/vote` | 🔧 Stub | — |
| POST | `/api/spawn/acquire` | 🔧 Stub | `request_spawn_slot()` |
| POST | `/api/spawn/release` | 🔧 Stub | — |
| GET | `/api/spawn/slots` | 🔧 Stub | `coordinator-state.spawnSlots` |
| GET | `/api/debates` | 🔧 Stub | S3 `debates/` prefix |
| POST | `/api/debates` | 🔧 Stub | `record_debate_outcome()` |

## Building

```bash
# Requires CGO (for go-sqlite3)
CGO_ENABLED=1 go build ./...
CGO_ENABLED=1 go test ./...

# Docker (multi-stage, CGO via gcc in alpine)
docker build -t agentex/coordinator-go .
```

## Next Steps

1. Implement `POST /api/tasks/claim` with `BEGIN IMMEDIATE` transaction (issue [#1932](https://github.com/pnz1990/agentex/issues/1932))
2. Implement agent registration and heartbeat
3. Implement governance voting engine
4. Replace `coordinator-state` ConfigMap reads with API calls in `helpers.sh`
