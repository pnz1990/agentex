-- =============================================================================
-- Agentex Work Ledger — SQLite Schema
-- Parent epic: #1827 (Structured work ledger)
-- Subtask: #1845 (Design SQLite schema)
-- =============================================================================
-- Purpose: Replace comma-separated ConfigMap strings with a typed, queryable
-- SQLite database backed by the Go coordinator (issue #1825).
--
-- Migration overview:
--   coordinator-state.taskQueue       -> tasks (status='queued')
--   coordinator-state.activeAssignments -> tasks (status='claimed', claimed_by set)
--   coordinator-state.enactedDecisions -> proposals (status='enacted')
--   coordinator-state.visionQueue     -> tasks (priority=1, source='vision')
--   coordinator-state.debateStats     -> SELECT COUNT(*) FROM debates / metrics
--   S3 debates/                       -> debates table
--   S3 identities/                    -> agent_activity + metrics tables
-- =============================================================================

PRAGMA journal_mode = WAL;      -- Allow concurrent readers + single writer
PRAGMA foreign_keys = ON;       -- Enforce referential integrity

-- =============================================================================
-- TASKS
-- Replaces: coordinator-state.taskQueue, activeAssignments, visionQueue
-- =============================================================================

CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    github_issue    INTEGER NOT NULL,
    title           TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','claimed','in_progress','pr_open','merged','done','failed')),
    priority        INTEGER NOT NULL DEFAULT 5
                    CHECK(priority BETWEEN 1 AND 10),
                    -- 1 = vision-queue (highest), 5 = normal, 10 = lowest
    source          TEXT NOT NULL DEFAULT 'coordinator'
                    CHECK(source IN ('coordinator','vision','god-directive','manual')),
    claimed_by      TEXT,           -- agent name that claimed this task (NULL = unclaimed)
    claimed_at      TIMESTAMP,      -- ISO-8601 UTC
    pre_claimed_at  TIMESTAMP,      -- coordinator pre-claim timestamp (for stale-claim protection)
    pr_number       INTEGER,        -- GitHub PR number once opened
    labels          TEXT,           -- JSON array of label strings: ["enhancement","bug"]
    depends_on      TEXT,           -- JSON array of task IDs this task depends on: [42, 17]
    effort          TEXT            -- 'S', 'M', 'L', 'XL' (from issue body)
                    CHECK(effort IS NULL OR effort IN ('S','M','L','XL')),
    specialization  TEXT,           -- matched specialization label that routed this task
    created_at      TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Enforce one unclaimed or one claimed-per-agent row per issue (no duplicates)
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_github_issue
    ON tasks(github_issue)
    WHERE status IN ('queued','claimed','in_progress','pr_open');

-- Speed up "find queued tasks ordered by priority"
CREATE INDEX IF NOT EXISTS idx_tasks_status_priority
    ON tasks(status, priority, created_at);

-- Speed up agent assignment lookups
CREATE INDEX IF NOT EXISTS idx_tasks_claimed_by
    ON tasks(claimed_by)
    WHERE claimed_by IS NOT NULL;

-- Trigger: keep updated_at fresh on every row change
CREATE TRIGGER IF NOT EXISTS trg_tasks_updated_at
    AFTER UPDATE ON tasks
    FOR EACH ROW
BEGIN
    UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE id = NEW.id;
END;

-- =============================================================================
-- AGENT ACTIVITY
-- Replaces: S3 identities/, coordinator-state.activeAgents
-- =============================================================================

CREATE TABLE IF NOT EXISTS agent_activity (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_name  TEXT NOT NULL,
    role        TEXT,                   -- 'worker', 'planner', 'architect', etc.
    action      TEXT NOT NULL,          -- 'registered', 'claimed', 'pr_opened', 'pr_merged',
                                        -- 'thought', 'debate', 'vote', 'report', 'spawned_successor'
    target      TEXT,                   -- issue number, PR number, thought ConfigMap name, etc.
    detail      TEXT,                   -- JSON payload with action-specific data
    generation  INTEGER,                -- civilization generation at time of action
    created_at  TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Speed up "what has agent X done recently?"
CREATE INDEX IF NOT EXISTS idx_agent_activity_agent_name
    ON agent_activity(agent_name, created_at DESC);

-- Speed up activity feed by action type
CREATE INDEX IF NOT EXISTS idx_agent_activity_action
    ON agent_activity(action, created_at DESC);

-- Speed up "who worked on issue #N?"
CREATE INDEX IF NOT EXISTS idx_agent_activity_target
    ON agent_activity(target, action);

-- =============================================================================
-- GOVERNANCE: PROPOSALS
-- Replaces: coordinator-state.enactedDecisions, voteRegistry
-- =============================================================================

CREATE TABLE IF NOT EXISTS proposals (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    topic       TEXT NOT NULL,      -- 'circuit-breaker', 'vision-feature', 'constitution', etc.
    proposer    TEXT NOT NULL,      -- agent name
    key         TEXT,               -- e.g. 'circuitBreakerLimit'
    value       TEXT,               -- e.g. '12'
    content     TEXT NOT NULL,      -- full proposal content from Thought CR
    status      TEXT NOT NULL DEFAULT 'open'
                CHECK(status IN ('open','enacted','rejected','expired')),
    enacted_at  TIMESTAMP,
    enacted_by  TEXT,               -- 'coordinator' typically
    created_at  TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_proposals_topic_status
    ON proposals(topic, status);

CREATE INDEX IF NOT EXISTS idx_proposals_status
    ON proposals(status, created_at DESC);

CREATE TRIGGER IF NOT EXISTS trg_proposals_updated_at
    AFTER UPDATE ON proposals
    FOR EACH ROW
BEGIN
    UPDATE proposals SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE id = NEW.id;
END;

-- =============================================================================
-- GOVERNANCE: VOTES
-- Replaces: coordinator-state.voteRegistry (partial)
-- =============================================================================

CREATE TABLE IF NOT EXISTS votes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    proposal_id INTEGER NOT NULL REFERENCES proposals(id) ON DELETE CASCADE,
    voter       TEXT NOT NULL,
    stance      TEXT NOT NULL CHECK(stance IN ('approve','reject','abstain')),
    reason      TEXT,
    created_at  TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(proposal_id, voter)  -- one vote per agent per proposal
);

CREATE INDEX IF NOT EXISTS idx_votes_proposal_id
    ON votes(proposal_id);

-- =============================================================================
-- DEBATES
-- Replaces: S3 debates/, coordinator-state.debateStats, coordinator-state.unresolvedDebates
-- =============================================================================

CREATE TABLE IF NOT EXISTS debates (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id       INTEGER REFERENCES debates(id),  -- NULL = root of a thread
    thread_id       TEXT NOT NULL,      -- hex hash linking all replies in one chain
    thought_name    TEXT,               -- Kubernetes ConfigMap name (e.g. thought-planner-abc-123)
    agent           TEXT NOT NULL,      -- agent name
    stance          TEXT NOT NULL CHECK(stance IN ('propose','agree','disagree','synthesize','insight')),
    content         TEXT NOT NULL,      -- full thought content
    confidence      INTEGER CHECK(confidence BETWEEN 1 AND 10),
    topic           TEXT,               -- keyword tag (e.g. 'circuit-breaker')
    file_ref        TEXT,               -- file path referenced (e.g. 'images/runner/entrypoint.sh')
    resolution      TEXT,               -- set when stance='synthesize': the synthesis text
    resolved        INTEGER NOT NULL DEFAULT 0  -- 0=open, 1=resolved/synthesized
                    CHECK(resolved IN (0, 1)),
    s3_persisted    INTEGER NOT NULL DEFAULT 0  -- 0=not persisted, 1=written to S3 debates/
                    CHECK(s3_persisted IN (0, 1)),
    created_at      TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Reconstruct a full debate thread: WHERE thread_id = ? ORDER BY created_at
CREATE INDEX IF NOT EXISTS idx_debates_thread_id
    ON debates(thread_id, created_at);

-- Find unresolved debates: WHERE resolved = 0
CREATE INDEX IF NOT EXISTS idx_debates_resolved
    ON debates(resolved, created_at DESC);

-- Topic search
CREATE INDEX IF NOT EXISTS idx_debates_topic
    ON debates(topic, created_at DESC);

-- Agent contribution lookup
CREATE INDEX IF NOT EXISTS idx_debates_agent
    ON debates(agent, created_at DESC);

-- =============================================================================
-- METRICS
-- Replaces: coordinator-state.debateStats, specializedAssignments, genericAssignments,
--           coordinator-state.routingCyclesWithZeroSpec, S3 identity stats
-- =============================================================================

CREATE TABLE IF NOT EXISTS metrics (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    metric      TEXT NOT NULL,      -- e.g. 'debate_responses', 'tasks_completed',
                                    -- 'specialized_assignments', 'generic_assignments',
                                    -- 'spawn_blocked', 'circuit_breaker_trips', etc.
    value       INTEGER NOT NULL,
    agent       TEXT,               -- NULL = civilization-wide; set = per-agent metric
    generation  INTEGER,            -- civilization generation at recording time
    recorded_at TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Dashboard query: SELECT metric, SUM(value) FROM metrics GROUP BY metric
CREATE INDEX IF NOT EXISTS idx_metrics_metric
    ON metrics(metric, recorded_at DESC);

-- Per-agent stats: SELECT metric, SUM(value) FROM metrics WHERE agent = ? GROUP BY metric
CREATE INDEX IF NOT EXISTS idx_metrics_agent
    ON metrics(agent, metric, recorded_at DESC);

-- Time-series aggregation: WHERE recorded_at >= datetime('now','-1 day')
CREATE INDEX IF NOT EXISTS idx_metrics_recorded_at
    ON metrics(recorded_at DESC);

-- =============================================================================
-- VISION QUEUE
-- Replaces: coordinator-state.visionQueue, coordinator-state.visionQueueLog
-- =============================================================================

CREATE TABLE IF NOT EXISTS vision_queue (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    feature     TEXT NOT NULL,          -- feature name or GitHub issue number (stringified)
    description TEXT,
    issue_num   INTEGER,                -- GitHub issue number if applicable
    proposer    TEXT NOT NULL,
    vote_count  INTEGER NOT NULL DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'active'
                CHECK(status IN ('active','in_progress','done','superseded')),
    enacted_at  TIMESTAMP,
    created_at  TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_vision_queue_status
    ON vision_queue(status, created_at);

-- =============================================================================
-- COORDINATOR STATE SNAPSHOT
-- Replaces: (parts of) coordinator-state ConfigMap — kept as cache for kubectl debugging
-- This table holds the latest values for fields that ConfigMap consumers still read.
-- The Go coordinator writes here on every state change; ConfigMap is rebuilt from this.
-- =============================================================================

CREATE TABLE IF NOT EXISTS coordinator_snapshot (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMP NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Initial keys that map 1:1 to ConfigMap fields
-- INSERT OR REPLACE used by coordinator to keep snapshot current:
-- key: 'generation', 'phase', 'lastHeartbeat', 'bootstrapped', etc.

-- =============================================================================
-- MIGRATION NOTES (ConfigMap -> SQLite)
-- =============================================================================
--
-- 1. taskQueue: "1782,1783,1784"
--      -> INSERT INTO tasks (github_issue, status) VALUES (1782,'queued'), ...
--
-- 2. activeAssignments: "worker-123:676,worker-456:789"
--      -> UPDATE tasks SET status='claimed', claimed_by='worker-123' WHERE github_issue=676
--
-- 3. enactedDecisions: "circuitBreakerLimit=6|2026-03-09|4-votes"
--      -> INSERT INTO proposals (topic, key, value, status, content, enacted_at)
--         VALUES ('circuit-breaker','circuitBreakerLimit','6','enacted','...',...)
--
-- 4. visionQueue: "feature:mentorship:2026-03-10:planner-42"
--      -> INSERT INTO vision_queue (feature, proposer, enacted_at)
--         VALUES ('mentorship', 'planner-42', '2026-03-10T...')
--
-- 5. debateStats: "responses=191 threads=110 disagree=37 synthesize=17"
--      -> SELECT COUNT(*) FROM debates         -- responses
--         SELECT COUNT(DISTINCT thread_id) FROM debates  -- threads
--         SELECT COUNT(*) FROM debates WHERE stance='disagree'
--         SELECT COUNT(*) FROM debates WHERE stance='synthesize'
--
-- 6. S3 debates/<thread-id>.json
--      -> INSERT INTO debates (thread_id, agent, stance, content, resolution, s3_persisted)
--         VALUES (?, ?, 'synthesize', ?, ?, 1)
--
-- =============================================================================
-- COMMON QUERY EXAMPLES
-- =============================================================================
--
-- Q: Find next queued task for a worker (respects priority, specialization-first):
-- SELECT * FROM tasks
-- WHERE status = 'queued'
-- ORDER BY priority ASC, created_at ASC
-- LIMIT 1;
--
-- Q: Atomic claim (use UNIQUE index + UPDATE ... WHERE claimed_by IS NULL):
-- UPDATE tasks SET status='claimed', claimed_by='worker-123', claimed_at=datetime('now')
-- WHERE github_issue=1782 AND claimed_by IS NULL;
-- -- Check changes() == 1 to confirm claim succeeded (0 = already taken)
--
-- Q: What has agent X done?
-- SELECT action, target, detail, created_at FROM agent_activity
-- WHERE agent_name = 'worker-123'
-- ORDER BY created_at DESC LIMIT 50;
--
-- Q: Agent completion rate:
-- SELECT
--   agent_name,
--   SUM(CASE WHEN action='pr_merged' THEN 1 ELSE 0 END) AS prs_merged,
--   SUM(CASE WHEN action='claimed' THEN 1 ELSE 0 END) AS tasks_claimed,
--   ROUND(100.0 * SUM(CASE WHEN action='pr_merged' THEN 1 ELSE 0 END) /
--         NULLIF(SUM(CASE WHEN action='claimed' THEN 1 ELSE 0 END), 0), 1) AS merge_rate_pct
-- FROM agent_activity
-- GROUP BY agent_name
-- ORDER BY prs_merged DESC;
--
-- Q: Rebuild debate thread:
-- WITH RECURSIVE thread AS (
--   SELECT * FROM debates WHERE thread_id = 'a3f2c8d1' AND parent_id IS NULL
--   UNION ALL
--   SELECT d.* FROM debates d JOIN thread t ON d.parent_id = t.id
-- )
-- SELECT * FROM thread ORDER BY created_at;
--
-- Q: Current governance vote tally:
-- SELECT p.topic, p.key, p.value, p.status,
--   SUM(CASE WHEN v.stance='approve' THEN 1 ELSE 0 END) AS approvals,
--   SUM(CASE WHEN v.stance='reject' THEN 1 ELSE 0 END) AS rejections
-- FROM proposals p LEFT JOIN votes v ON v.proposal_id = p.id
-- WHERE p.status = 'open'
-- GROUP BY p.id;
--
-- Q: Civilization dashboard snapshot:
-- SELECT metric, SUM(value) AS total
-- FROM metrics
-- WHERE recorded_at >= datetime('now','-24 hours')
-- GROUP BY metric
-- ORDER BY metric;
--
-- Q: Agents with most specialization label matches:
-- SELECT aa.agent_name, aa.detail ->> '$.labels' AS labels, COUNT(*) AS tasks_worked
-- FROM agent_activity aa
-- WHERE aa.action = 'claimed'
-- GROUP BY aa.agent_name
-- ORDER BY tasks_worked DESC;
-- =============================================================================
