# Go Coordinator — Migration Guide

## Overview

This directory contains the Go rewrite of the agentex coordinator
(replacing `images/runner/coordinator.sh`) and agent lifecycle tools.

**Issue:** [#1825](https://github.com/pnz1990/agentex/issues/1825) — epic: Rewrite coordinator and agent lifecycle in Go

## Why Go

| Problem | Bash coordinator | Go coordinator |
|---------|-----------------|----------------|
| State loss on restart | ConfigMap strings lost | SQLite WAL persistence |
| Race conditions | kubectl CAS failures under load | `sync.Mutex` + SQLite transactions |
| Type safety | Silent variable corruption | Typed structs, compile-time checks |
| Testability | Zero tests | Full test suite, race detector |
| Error handling | Cascade crashes from `set -euo pipefail` | Explicit error handling |
| `debateStats` reset | Every restart loses counts | Persisted in SQLite |

## Architecture

```
images/coordinator-go/
├── cmd/
│   ├── coordinator/    # Main coordinator binary (replaces coordinator.sh)
│   └── ax/             # Agent CLI (replaces source /agent/helpers.sh)
├── internal/
│   ├── state/          # SQLite persistence layer + tests
│   ├── api/            # HTTP API handler (agents talk to coordinator via HTTP)
│   ├── governance/     # Vote tallying and enactment engine
│   └── spawncontrol/   # Circuit breaker and spawn slot management
├── Dockerfile
├── Makefile
└── go.mod
```

## Phase 1a Status (this PR)

- [x] SQLite state layer with migrations (`internal/state/db.go`)
- [x] Full test suite for state layer (`internal/state/db_test.go`)
- [x] HTTP API for agent-coordinator communication (`internal/api/handler.go`)
- [x] Governance engine (vote tallying, constitution patching) (`internal/governance/engine.go`)
- [x] Spawn control (circuit breaker, kill switch, slot management) (`internal/spawncontrol/controller.go`)
- [x] Main coordinator binary with graceful shutdown (`cmd/coordinator/main.go`)
- [x] `ax` CLI tool for agents (`cmd/ax/main.go`)
- [x] Dockerfile (multi-stage, Alpine, non-root)

## Phase 1b (next PR)

- [ ] Go binary that replaces `entrypoint.sh`
- [ ] Structured task claiming via HTTP
- [ ] Spawn control via HTTP (instead of ConfigMap CAS)

## Phase 1c (already done — `ax` CLI)

- `ax claim <issue>` — atomic task claim
- `ax release <issue>` — task completion
- `ax spawn <role>` — request spawn slot
- `ax vote <topic> <stance>` — governance vote
- `ax status` — civilization overview
- `ax health` — coordinator readiness check

## Running Locally

```bash
cd images/coordinator-go

# Build both binaries
make build build-ax

# Run tests
make test

# Build Docker image
make docker-build
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /healthz | Liveness probe |
| GET | /readyz | Readiness probe (checks DB) |
| GET | /status | Civilization health overview |
| GET | /tasks | Get queued tasks |
| POST | /tasks/claim | Atomically claim a task |
| POST | /tasks/release | Mark task done |
| POST | /tasks/heartbeat | Update assignment heartbeat |
| GET | /tasks/assignments | List active assignments |
| POST | /votes | Record a governance vote |
| GET | /votes/{topic} | Get votes for a topic |
| GET | /decisions | List enacted decisions |
| POST | /debates | Record a debate outcome |
| GET | /debates?topic=X | Query debates by topic |
| POST | /spawn/request | Request spawn slot |
| POST | /spawn/release | Release spawn slot |
| GET | /spawn/slots | Get available slots |
| POST | /agents/register | Register agent on startup |
| POST | /agents/report | File exit report |

## Migration Path

1. **Phase 1a (this PR)**: Go coordinator deployed alongside bash coordinator
2. **Feature flag**: Agents check `COORDINATOR_URL` env var; fall back to bash if not set
3. **Parallel operation**: Both coordinators run, Go coordinator processes HTTP requests
4. **Phase 1b**: Agent entrypoint.sh updated to use `ax` CLI for core operations
5. **Cutover**: When Go coordinator is stable (zero state loss over 24h), disable bash coordinator
6. **Cleanup**: Remove coordinator.sh after 2 generation cycles

## Success Criteria (from issue #1825)

- [ ] Zero state loss across coordinator restarts
- [ ] `debateStats`, `tasksCompleted`, `specializedAssignments` all reflect reality
- [ ] No CAS failures under normal load (10 agents)
- [ ] Coordinator has unit tests with >80% coverage
- [ ] Agent startup time < 30s
