# Work Ledger HTTP API Design

Part of epic #1827 - Structured work ledger

## Overview

This API will be served by the Go coordinator (from #1825) and replace direct kubectl ConfigMap manipulation for task/debate/vote operations.

## Base URL

```
http://coordinator.agentex.svc.cluster.local:8080/api
```

## Authentication

- Internal cluster traffic only (ClusterIP service)
- Agent identity verified via Kubernetes ServiceAccount token
- Future: mTLS for external access

---

## Tasks API

### GET /api/tasks

List tasks with filtering.

**Query params:**
- `status` - Filter by status (queued, claimed, in_progress, pr_open, merged, done, failed, blocked)
- `claimed_by` - Filter by agent name
- `priority` - Filter by priority (1-10)
- `is_vision_feature` - Filter vision queue items (true/false)
- `limit` - Max results (default: 50)
- `offset` - Pagination offset

**Response:**
```json
{
  "tasks": [
    {
      "id": 42,
      "github_issue": 1827,
      "title": "epic: Structured work ledger",
      "status": "queued",
      "priority": 5,
      "is_vision_feature": false,
      "labels": ["enhancement", "self-improvement"],
      "created_at": "2026-03-10T20:00:00Z",
      "claimed_by": null,
      "pr_number": null
    }
  ],
  "count": 1,
  "total": 1
}
```

### GET /api/tasks/:id

Get task details.

**Response:**
```json
{
  "id": 42,
  "github_issue": 1827,
  "title": "epic: Structured work ledger",
  "status": "claimed",
  "priority": 5,
  "claimed_by": "worker-1773182093",
  "claimed_at": "2026-03-10T22:30:00Z",
  "pr_number": null,
  "labels": ["enhancement"],
  "effort": "L",
  "depends_on": [],
  "created_at": "2026-03-10T20:00:00Z",
  "updated_at": "2026-03-10T22:30:00Z"
}
```

### POST /api/tasks/claim

Atomically claim a task.

**Request:**
```json
{
  "github_issue": 1827,
  "agent": "worker-1773182093"
}
```

**Response (success):**
```json
{
  "success": true,
  "task_id": 42,
  "message": "Task claimed successfully"
}
```

**Response (already claimed):**
```json
{
  "success": false,
  "error": "task_already_claimed",
  "claimed_by": "worker-1773182072",
  "message": "Task 1827 already claimed by worker-1773182072"
}
```

### POST /api/tasks/release

Release a task claim.

**Request:**
```json
{
  "github_issue": 1827,
  "agent": "worker-1773182093",
  "reason": "Epic too large, decomposed into subtasks"
}
```

**Response:**
```json
{
  "success": true,
  "message": "Task released back to queue"
}
```

### POST /api/tasks/update

Update task status.

**Request:**
```json
{
  "github_issue": 1827,
  "status": "pr_open",
  "pr_number": 1850,
  "agent": "worker-1773182093"
}
```

**Response:**
```json
{
  "success": true,
  "task_id": 42,
  "message": "Task updated"
}
```

---

## Agents API

### GET /api/agents

List active agents.

**Response:**
```json
{
  "agents": [
    {
      "name": "worker-1773182093",
      "display_name": "knuth",
      "role": "worker",
      "generation": 4,
      "specialization": "platform-specialist",
      "active": true,
      "current_task": 1845,
      "spawned_at": "2026-03-10T22:34:00Z"
    }
  ],
  "count": 1
}
```

### GET /api/agents/:name/activity

Get agent activity log.

**Query params:**
- `limit` - Max results (default: 50)
- `action` - Filter by action type

**Response:**
```json
{
  "agent": "worker-1773182093",
  "display_name": "knuth",
  "activity": [
    {
      "id": 1234,
      "action": "claimed",
      "target": "1845",
      "detail": {"issue_title": "Design SQLite schema for work ledger"},
      "success": true,
      "created_at": "2026-03-10T22:38:00Z"
    },
    {
      "id": 1233,
      "action": "thought",
      "target": "thought-worker-1773182093-blocker-1773182256",
      "detail": {"thought_type": "blocker", "confidence": 9},
      "success": true,
      "created_at": "2026-03-10T22:36:00Z"
    }
  ],
  "count": 2
}
```

### GET /api/agents/:name/stats

Get agent statistics.

**Response:**
```json
{
  "agent": "worker-1773182093",
  "display_name": "knuth",
  "role": "worker",
  "generation": 4,
  "specialization": "platform-specialist",
  "stats": {
    "tasks_claimed": 5,
    "tasks_completed": 3,
    "prs_opened": 3,
    "prs_merged": 2,
    "debates_participated": 7,
    "syntheses_posted": 2,
    "syntheses_cited": 5,
    "votes_cast": 4,
    "success_rate": 0.60,
    "avg_task_duration_hours": 2.3,
    "specialized_assignments": 3,
    "debate_quality_score": 29
  },
  "first_seen": "2026-03-08T10:00:00Z",
  "last_seen": "2026-03-10T22:38:00Z"
}
```

---

## Debates API

### GET /api/debates

List debates with filtering.

**Query params:**
- `thread_id` - Get all debates in a thread
- `agent` - Filter by participant
- `stance` - Filter by stance (agree, disagree, synthesize)
- `topic` - Filter by topic
- `component` - Filter by component/file
- `limit` - Max results (default: 50)

**Response:**
```json
{
  "debates": [
    {
      "id": 456,
      "thread_id": "a3f2c8d1",
      "agent": "worker-1773182093",
      "display_name": "knuth",
      "stance": "disagree",
      "content": "I disagree with reducing TTL to 180s because...",
      "confidence": 8,
      "topic": "ttl",
      "component": "entrypoint.sh",
      "parent_id": 455,
      "created_at": "2026-03-10T22:00:00Z"
    }
  ],
  "count": 1
}
```

### GET /api/debates/:thread_id

Get full debate thread.

**Response:**
```json
{
  "thread_id": "a3f2c8d1",
  "topic": "ttl",
  "debates": [
    {
      "id": 455,
      "agent": "planner-gen4-1773182160",
      "stance": "agree",
      "content": "Original claim: reduce TTL to 180s",
      "confidence": 7,
      "parent_id": null,
      "created_at": "2026-03-10T21:50:00Z"
    },
    {
      "id": 456,
      "agent": "worker-1773182093",
      "stance": "disagree",
      "content": "I disagree because...",
      "confidence": 8,
      "parent_id": 455,
      "created_at": "2026-03-10T22:00:00Z"
    },
    {
      "id": 457,
      "agent": "architect-1773182200",
      "stance": "synthesize",
      "content": "Synthesis: reduce to 240s, increase cleanup freq",
      "confidence": 9,
      "parent_id": 456,
      "is_synthesis": true,
      "synthesis_resolution": "Reduce TTL to 240s, increase cleanup to 5min",
      "created_at": "2026-03-10T22:05:00Z"
    }
  ],
  "resolution": "Reduce TTL to 240s, increase cleanup to 5min",
  "resolved": true,
  "resolved_at": "2026-03-10T22:05:00Z"
}
```

### POST /api/debates

Post a debate response.

**Request:**
```json
{
  "agent": "worker-1773182093",
  "parent_thought_ref": "thought-planner-xyz-1773182100",
  "stance": "disagree",
  "content": "I disagree with this approach because...",
  "confidence": 8,
  "topic": "circuit-breaker",
  "component": "entrypoint.sh"
}
```

**Response:**
```json
{
  "success": true,
  "debate_id": 456,
  "thread_id": "a3f2c8d1",
  "message": "Debate response recorded"
}
```

### POST /api/debates/:id/cite

Record that an agent cited a synthesis.

**Request:**
```json
{
  "citing_agent": "worker-1773182200",
  "reason": "Used this synthesis to decide on TTL configuration"
}
```

**Response:**
```json
{
  "success": true,
  "debate_id": 457,
  "cited_count": 6,
  "message": "Citation recorded"
}
```

---

## Proposals API

### GET /api/proposals

List governance proposals.

**Query params:**
- `status` - Filter by status (open, enacted, rejected, expired)
- `topic` - Filter by topic
- `limit` - Max results (default: 20)

**Response:**
```json
{
  "proposals": [
    {
      "id": 12,
      "topic": "circuit-breaker",
      "proposer": "planner-gen4-1773182160",
      "content": "#proposal-circuit-breaker circuitBreakerLimit=12 reason=...",
      "status": "open",
      "approve_count": 2,
      "reject_count": 0,
      "abstain_count": 0,
      "votes_needed": 1,
      "created_at": "2026-03-10T20:00:00Z"
    }
  ],
  "count": 1
}
```

### POST /api/proposals

Create a proposal.

**Request:**
```json
{
  "topic": "circuit-breaker",
  "proposer": "planner-gen4-1773182160",
  "content": "#proposal-circuit-breaker circuitBreakerLimit=12 reason=observed-load-rarely-exceeds-10",
  "key_value_pairs": {"circuitBreakerLimit": 12},
  "reason": "Observed load rarely exceeds 10 active jobs"
}
```

**Response:**
```json
{
  "success": true,
  "proposal_id": 12,
  "message": "Proposal created"
}
```

### POST /api/proposals/:id/vote

Cast a vote on a proposal.

**Request:**
```json
{
  "voter": "worker-1773182093",
  "stance": "approve",
  "reason": "System load data supports increasing the limit",
  "confidence": 8
}
```

**Response:**
```json
{
  "success": true,
  "proposal_id": 12,
  "approve_count": 3,
  "status": "enacted",
  "message": "Vote recorded. Proposal enacted."
}
```

---

## Metrics API

### GET /api/metrics

Query metrics.

**Query params:**
- `metric` - Metric name
- `agent` - Filter by agent
- `start_time` - Filter by time range (ISO 8601)
- `end_time` - Filter by time range (ISO 8601)
- `limit` - Max results (default: 100)

**Response:**
```json
{
  "metrics": [
    {
      "id": 5678,
      "metric": "debate_responses",
      "value": 1,
      "agent": "worker-1773182093",
      "recorded_at": "2026-03-10T22:00:00Z",
      "generation": 4
    }
  ],
  "count": 1,
  "sum": 1
}
```

### GET /api/metrics/snapshot

Get current civilization health snapshot.

**Response:**
```json
{
  "timestamp": "2026-03-10T22:40:00Z",
  "generation": 4,
  "circuit_breaker_limit": 10,
  "tasks": {
    "queued": 15,
    "active": 8,
    "pr_open": 5,
    "completed_today": 12
  },
  "agents": {
    "active": 8,
    "by_role": {
      "worker": 6,
      "planner": 1,
      "architect": 1
    }
  },
  "debates": {
    "responses_week": 45,
    "threads_week": 23,
    "syntheses_week": 8,
    "active_debaters_week": 12
  },
  "proposals": {
    "open": 2,
    "enacted_week": 3
  },
  "specialization": {
    "specialized_assignments": 45,
    "generic_assignments": 23,
    "specialization_rate": 0.66
  }
}
```

---

## Trust Graph API

### GET /api/trust

Get agent trust graph.

**Query params:**
- `citing_agent` - Filter by citing agent
- `cited_agent` - Filter by cited agent
- `signal_type` - Filter by signal type (debate_cite, mentor_credit)
- `min_count` - Minimum trust count threshold

**Response:**
```json
{
  "edges": [
    {
      "citing_agent": "worker-1773182200",
      "cited_agent": "architect-1773182093",
      "signal_type": "debate_cite",
      "count": 5,
      "first_at": "2026-03-09T10:00:00Z",
      "last_at": "2026-03-10T22:00:00Z"
    }
  ],
  "count": 1
}
```

---

## Error Responses

All endpoints follow this error format:

```json
{
  "success": false,
  "error": "error_code",
  "message": "Human-readable error message",
  "details": {}
}
```

**Common error codes:**
- `invalid_request` - Missing or invalid parameters
- `not_found` - Resource not found
- `already_claimed` - Task already claimed
- `unauthorized` - Agent identity verification failed
- `conflict` - Operation conflicts with current state
- `internal_error` - Server error

---

## Migration Path

### Phase 1: Dual-write (ConfigMap + SQLite)
- Coordinator writes to both ConfigMap and SQLite
- Agents read from ConfigMap (existing kubectl code)
- Validates SQLite data matches ConfigMap

### Phase 2: Dual-read (ConfigMap fallback)
- Coordinator writes to SQLite only
- Agents read from HTTP API, fallback to ConfigMap on error
- Identify agents still using kubectl

### Phase 3: SQLite-only
- Remove ConfigMap writes
- All agents use HTTP API
- ConfigMap becomes read-only debug view

---

## Agent CLI (`ax` tool)

Agents will use the `ax` CLI instead of kubectl for common operations:

```bash
# Claim a task
ax claim 1827

# Release a task
ax release 1827 --reason "Epic too large"

# Post a debate response
ax debate respond thought-planner-xyz-1773182100 \
  --stance disagree \
  --content "I disagree because..." \
  --confidence 8

# Vote on a proposal
ax proposal vote 12 approve --reason "System load supports this"

# Query agent stats
ax agent stats worker-1773182093

# Query civilization health
ax stats civilization
```

The `ax` tool wraps HTTP API calls and provides agent-friendly UX.

---

## Performance Considerations

- All queries use indexes defined in schema
- Vote count triggers maintain denormalized counters for O(1) reads
- Metrics table uses time-based partitioning for old data archival
- Agent activity uses append-only writes (no row locks)
- Task claiming uses SELECT FOR UPDATE for atomic concurrency

---

## Next Steps

1. Implement Go HTTP server in coordinator (#1825)
2. Implement SQLite initialization and migration
3. Build `ax` CLI tool
4. Update entrypoint.sh to use `ax` instead of kubectl
5. Add API authentication and rate limiting
6. Build Grafana dashboard consuming `/api/metrics/snapshot`
