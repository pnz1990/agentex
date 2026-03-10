-- =============================================================================
-- Agentex Work Ledger SQLite Schema
-- Issue #1845 (subtask of epic #1827)
--
-- Purpose: Replace coordinator-state ConfigMap string fields with a queryable,
-- atomic, crash-safe SQLite database. This schema is the design foundation for
-- the structured work ledger described in epic #1827.
--
-- Design principles:
--   1. Atomic task claiming via UNIQUE constraints (replaces CAS on ConfigMap strings)
--   2. Debate thread reconstruction via parent_id foreign keys
--   3. Full agent activity history (replaces Thought CR enumeration)
--   4. Time-series metrics aggregation (replaces debateStats strings)
--   5. Migration-friendly: every table has a ConfigMap equivalent documented
-- =============================================================================

PRAGMA journal_mode = WAL;       -- Write-Ahead Logging for concurrent reads
PRAGMA foreign_keys = ON;        -- Enforce referential integrity
PRAGMA synchronous = NORMAL;     -- Balance durability vs. performance


-- =============================================================================
-- TABLE: tasks
-- Replaces: coordinator-state.taskQueue (comma-separated), activeAssignments,
--           preClaimTimestamps, issueLabels
-- Purpose: Track every GitHub issue as a claimable task with full status lifecycle
-- =============================================================================
CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_number    INTEGER NOT NULL UNIQUE,   -- GitHub issue number (enforces no duplicates)
    title           TEXT,                       -- Cached from GitHub API
    labels          TEXT,                       -- JSON array: ["bug","self-improvement"]
    state           TEXT NOT NULL DEFAULT 'queued'
                        CHECK (state IN ('queued', 'claimed', 'in_progress', 'done', 'cancelled')),
    claimed_by      TEXT,                       -- Agent name (e.g., "worker-1773184805")
    claimed_at      TEXT,                       -- ISO 8601 timestamp
    completed_at    TEXT,                       -- ISO 8601 timestamp (NULL until done)
    pr_number       INTEGER,                    -- GitHub PR opened for this task (NULL until opened)
    effort          TEXT CHECK (effort IN ('XS', 'S', 'M', 'L', 'XL')),
    vision_queue    INTEGER NOT NULL DEFAULT 0, -- 1 if added to civilization visionQueue
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Atomic claiming: only one agent can hold a 'claimed' state for an issue at a time.
-- The UNIQUE constraint on issue_number already enforces this.
-- To claim: INSERT OR IGNORE + check rows_affected, or UPDATE WHERE state='queued'.
CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);
CREATE INDEX IF NOT EXISTS idx_tasks_claimed_by ON tasks(claimed_by);
CREATE INDEX IF NOT EXISTS idx_tasks_vision_queue ON tasks(vision_queue) WHERE vision_queue = 1;

-- Migration from ConfigMap:
--   taskQueue        → SELECT issue_number FROM tasks WHERE state = 'queued' ORDER BY created_at
--   activeAssignments → SELECT claimed_by, issue_number FROM tasks WHERE state IN ('claimed','in_progress')
--   preClaimTimestamps → claimed_at column
--   issueLabels      → labels column (JSON)


-- =============================================================================
-- TABLE: agent_activity
-- Replaces: coordinator-state.activeAgents (partial), Thought CRs (partial),
--           Report CRs (partial)
-- Purpose: Immutable audit log of every significant agent action
-- =============================================================================
CREATE TABLE IF NOT EXISTS agent_activity (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_name      TEXT NOT NULL,              -- e.g., "worker-1773184805"
    display_name    TEXT,                        -- e.g., "ada"
    role            TEXT NOT NULL CHECK (role IN ('planner', 'worker', 'reviewer', 'architect', 'god-delegate', 'seed', 'coordinator')),
    generation      INTEGER,                     -- From Agent CR label agentex/generation
    action_type     TEXT NOT NULL CHECK (action_type IN (
                        'started', 'claimed_task', 'opened_pr', 'spawned_agent',
                        'posted_thought', 'posted_debate', 'posted_vote',
                        'posted_proposal', 'completed_task', 'failed',
                        'milestone_check', 'heartbeat'
                    )),
    issue_number    INTEGER REFERENCES tasks(issue_number),
    pr_number       INTEGER,
    target_agent    TEXT,                        -- For spawned_agent actions
    details         TEXT,                        -- JSON blob for action-specific data
    vision_score    INTEGER CHECK (vision_score BETWEEN 1 AND 10),  -- For completed_task actions
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_activity_agent ON agent_activity(agent_name);
CREATE INDEX IF NOT EXISTS idx_activity_type ON agent_activity(action_type);
CREATE INDEX IF NOT EXISTS idx_activity_issue ON agent_activity(issue_number);
CREATE INDEX IF NOT EXISTS idx_activity_created ON agent_activity(created_at);
CREATE INDEX IF NOT EXISTS idx_activity_role_gen ON agent_activity(role, generation);

-- Migration from ConfigMap:
--   activeAgents     → SELECT DISTINCT agent_name, role FROM agent_activity
--                       WHERE action_type = 'started' AND created_at > (now - 2h)
--   Report CR data   → action_type = 'completed_task' rows with vision_score and details


-- =============================================================================
-- TABLE: proposals
-- Replaces: coordinator-state.voteRegistry_* (multiple keys), enactedDecisions,
--           Thought CRs with thoughtType=proposal
-- Purpose: Governance proposals with full lifecycle tracking
-- =============================================================================
CREATE TABLE IF NOT EXISTS proposals (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    topic           TEXT NOT NULL,              -- e.g., "circuit-breaker", "vision-feature"
    key             TEXT,                        -- e.g., "circuitBreakerLimit"
    value           TEXT,                        -- e.g., "12"
    description     TEXT,                        -- Human-readable summary
    proposed_by     TEXT NOT NULL,               -- Agent name
    state           TEXT NOT NULL DEFAULT 'open'
                        CHECK (state IN ('open', 'enacted', 'rejected', 'expired')),
    vote_approve    INTEGER NOT NULL DEFAULT 0,
    vote_reject     INTEGER NOT NULL DEFAULT 0,
    vote_abstain    INTEGER NOT NULL DEFAULT 0,
    threshold       INTEGER NOT NULL DEFAULT 3, -- Votes needed to enact
    enacted_at      TEXT,                        -- ISO 8601 timestamp
    enacted_value   TEXT,                        -- Final value after enactment
    thought_cr_name TEXT,                        -- Thought ConfigMap name (cross-reference)
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_proposals_topic_key ON proposals(topic, key) WHERE state = 'open';
CREATE INDEX IF NOT EXISTS idx_proposals_state ON proposals(state);
CREATE INDEX IF NOT EXISTS idx_proposals_proposed_by ON proposals(proposed_by);

-- Migration from ConfigMap:
--   voteRegistry_*   → proposals table WHERE state = 'open'
--   enactedDecisions → proposals table WHERE state = 'enacted'
--   decisionLog      → proposals table + audit via agent_activity


-- =============================================================================
-- TABLE: votes
-- Replaces: coordinator-state.voteRegistry_* (vote tallies within each key)
-- Purpose: Individual vote records (not just tallies) for audit trail
-- =============================================================================
CREATE TABLE IF NOT EXISTS votes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    proposal_id     INTEGER NOT NULL REFERENCES proposals(id) ON DELETE CASCADE,
    voter           TEXT NOT NULL,               -- Agent name
    stance          TEXT NOT NULL CHECK (stance IN ('approve', 'reject', 'abstain')),
    reason          TEXT,                         -- Free-text reasoning
    thought_cr_name TEXT,                         -- Cross-reference to Thought CR
    voted_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_votes_unique ON votes(proposal_id, voter);
CREATE INDEX IF NOT EXISTS idx_votes_proposal ON votes(proposal_id);

-- Tally query (replaces coordinator tally_votes bash loop):
-- SELECT stance, COUNT(*) FROM votes WHERE proposal_id = ? GROUP BY stance


-- =============================================================================
-- TABLE: debates
-- Replaces: coordinator-state.unresolvedDebates, coordinator-state.debateStats,
--           S3 debates/*.json, Thought CRs with thoughtType=debate
-- Purpose: Full debate thread storage with parent-child chain reconstruction
-- =============================================================================
CREATE TABLE IF NOT EXISTS debates (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id       TEXT NOT NULL,               -- SHA256-derived thread identifier
    thought_cr_name TEXT UNIQUE,                  -- Thought ConfigMap name (cross-ref)
    parent_id       INTEGER REFERENCES debates(id),  -- NULL = root thought, non-NULL = response
    agent_name      TEXT NOT NULL,
    display_name    TEXT,
    stance          TEXT CHECK (stance IN ('propose', 'agree', 'disagree', 'synthesize', NULL)),
    content         TEXT NOT NULL,
    confidence      INTEGER CHECK (confidence BETWEEN 1 AND 10),
    topic           TEXT,                         -- e.g., "circuit-breaker", "spawn-control"
    component       TEXT,                         -- e.g., "coordinator.sh", "entrypoint.sh"
    is_resolved     INTEGER NOT NULL DEFAULT 0 CHECK (is_resolved IN (0, 1)),
    resolution      TEXT,                         -- Synthesis text when is_resolved=1
    resolved_by     TEXT,                         -- Agent name who synthesized
    resolved_at     TEXT,                         -- ISO 8601 timestamp
    s3_path         TEXT,                         -- e.g., "debates/<thread-id>.json"
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_debates_thread ON debates(thread_id);
CREATE INDEX IF NOT EXISTS idx_debates_parent ON debates(parent_id);
CREATE INDEX IF NOT EXISTS idx_debates_agent ON debates(agent_name);
CREATE INDEX IF NOT EXISTS idx_debates_topic ON debates(topic);
CREATE INDEX IF NOT EXISTS idx_debates_component ON debates(component);
CREATE INDEX IF NOT EXISTS idx_debates_unresolved ON debates(is_resolved) WHERE is_resolved = 0;
CREATE INDEX IF NOT EXISTS idx_debates_stance ON debates(stance);

-- Thread reconstruction query (replaces kubectl + jq chain):
-- WITH RECURSIVE thread AS (
--   SELECT * FROM debates WHERE id = ?
--   UNION ALL
--   SELECT d.* FROM debates d JOIN thread t ON d.parent_id = t.id
-- ) SELECT * FROM thread ORDER BY created_at;

-- Migration from ConfigMap:
--   unresolvedDebates → SELECT thought_cr_name FROM debates WHERE is_resolved = 0
--   debateStats       → SELECT stance, COUNT(*) FROM debates GROUP BY stance
-- Migration from S3:
--   debates/*.json    → Import into debates table (resolved rows with s3_path set)


-- =============================================================================
-- TABLE: metrics
-- Replaces: coordinator-state.debateStats, specializedAssignments,
--           genericAssignments, routingCyclesWithZeroSpec, v05CriteriaStatus, etc.
-- Purpose: Time-series counters for civilization-level observability
-- =============================================================================
CREATE TABLE IF NOT EXISTS metrics (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,               -- e.g., "debate_responses", "spawn_attempts"
    value           REAL NOT NULL,
    labels          TEXT,                         -- JSON: {"role":"worker","generation":"4"}
    recorded_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_metrics_name_time ON metrics(name, recorded_at);
CREATE INDEX IF NOT EXISTS idx_metrics_recorded ON metrics(recorded_at);

-- Current value query (latest for each metric name):
-- SELECT name, value, recorded_at FROM metrics m1
-- WHERE recorded_at = (SELECT MAX(recorded_at) FROM metrics m2 WHERE m2.name = m1.name);

-- Time-range aggregation (replaces debateStats string parsing):
-- SELECT name, SUM(value) FROM metrics
-- WHERE name LIKE 'debate_%' AND recorded_at > datetime('now', '-1 hour')
-- GROUP BY name;

-- Migration from ConfigMap strings:
--   debateStats "responses=191 threads=110 disagree=37 synthesize=17"
--     → INSERT INTO metrics (name, value) VALUES
--         ('debate_responses', 191), ('debate_threads', 110),
--         ('debate_disagree', 37), ('debate_synthesize', 17)
--   specializedAssignments → INSERT INTO metrics (name, value) VALUES ('specialized_assignments', N)
--   genericAssignments     → INSERT INTO metrics (name, value) VALUES ('generic_assignments', N)
--   routingCyclesWithZeroSpec → INSERT INTO metrics (name, value) VALUES ('routing_cycles_zero_spec', N)


-- =============================================================================
-- TABLE: vision_queue
-- Replaces: coordinator-state.visionQueue (semicolon-separated),
--           coordinator-state.visionQueueLog
-- Purpose: Civilization self-direction goals voted in by agents
-- =============================================================================
CREATE TABLE IF NOT EXISTS vision_queue (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    feature_name    TEXT NOT NULL,               -- e.g., "mentorship-chains"
    description     TEXT,
    issue_number    INTEGER REFERENCES tasks(issue_number),
    proposed_by     TEXT NOT NULL,
    vote_count      INTEGER NOT NULL DEFAULT 0,
    state           TEXT NOT NULL DEFAULT 'queued'
                        CHECK (state IN ('queued', 'claimed', 'completed', 'cancelled')),
    priority        INTEGER NOT NULL DEFAULT 50, -- Lower = higher priority (planner ordering)
    enqueued_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_vision_queue_state ON vision_queue(state, priority);

-- Planner reads this before taskQueue (replaces bash visionQueue string parsing):
-- SELECT * FROM vision_queue WHERE state = 'queued' ORDER BY priority ASC, enqueued_at ASC LIMIT 1


-- =============================================================================
-- VIEWS (common query patterns for coordinator and agents)
-- =============================================================================

-- Current task queue (replaces coordinator-state.taskQueue comma-string):
CREATE VIEW IF NOT EXISTS v_task_queue AS
SELECT issue_number, title, labels, effort, created_at
FROM tasks
WHERE state = 'queued'
ORDER BY
    vision_queue DESC,          -- Vision queue items first
    created_at ASC;             -- FIFO within each tier

-- Active agent assignments (replaces coordinator-state.activeAssignments):
CREATE VIEW IF NOT EXISTS v_active_assignments AS
SELECT claimed_by AS agent_name, issue_number, claimed_at
FROM tasks
WHERE state IN ('claimed', 'in_progress')
  AND claimed_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-2 hours');

-- Debate health summary (replaces debateStats string):
CREATE VIEW IF NOT EXISTS v_debate_stats AS
SELECT
    COUNT(*) AS total_responses,
    COUNT(DISTINCT thread_id) AS total_threads,
    SUM(CASE WHEN stance = 'disagree' THEN 1 ELSE 0 END) AS disagree_count,
    SUM(CASE WHEN stance = 'synthesize' THEN 1 ELSE 0 END) AS synthesize_count,
    SUM(CASE WHEN is_resolved = 0 THEN 1 ELSE 0 END) AS unresolved_count
FROM debates;

-- Governance proposal status (replaces voteRegistry_* individual keys):
CREATE VIEW IF NOT EXISTS v_open_proposals AS
SELECT
    p.id, p.topic, p.key, p.value, p.proposed_by,
    p.vote_approve, p.vote_reject, p.vote_abstain,
    p.threshold,
    (p.vote_approve >= p.threshold) AS ready_to_enact,
    p.created_at
FROM proposals p
WHERE p.state = 'open'
ORDER BY p.created_at DESC;


-- =============================================================================
-- MIGRATION NOTES: ConfigMap → SQLite
-- =============================================================================

-- PHASE 1 (read-only shadow): SQLite populated from coordinator reads ConfigMap.
--   Both systems run in parallel. No ConfigMap writes go to SQLite yet.
--   Validation: Compare ConfigMap values vs. SQLite query results hourly.

-- PHASE 2 (dual-write): Coordinator writes to BOTH ConfigMap and SQLite.
--   Reads still from ConfigMap (zero behavior change). SQLite accumulates history.

-- PHASE 3 (read from SQLite): Coordinator reads task queue and assignments from SQLite.
--   ConfigMap still updated as backup. Atomic claim uses SQLite UPDATE + WHERE.

-- PHASE 4 (ConfigMap as cache): SQLite is source of truth.
--   ConfigMap updated every N seconds as human-readable summary for kubectl debugging.

-- Key mapping (ConfigMap key → SQLite equivalent):
--   taskQueue                  → v_task_queue view
--   activeAssignments          → v_active_assignments view
--   decisionLog                → agent_activity WHERE action_type IN ('posted_proposal','milestone_check')
--   voteRegistry_<topic>       → votes JOIN proposals WHERE proposals.topic = <topic>
--   enactedDecisions           → proposals WHERE state = 'enacted'
--   visionQueue                → vision_queue WHERE state = 'queued' ORDER BY priority
--   visionQueueLog             → vision_queue (full table with enqueued_at)
--   debateStats                → v_debate_stats view
--   unresolvedDebates          → debates WHERE is_resolved = 0
--   specializedAssignments     → metrics WHERE name = 'specialized_assignments' (latest)
--   genericAssignments         → metrics WHERE name = 'generic_assignments' (latest)
--   spawnSlots                 → metrics WHERE name = 'spawn_slots' (latest)
--   routingCyclesWithZeroSpec  → metrics WHERE name = 'routing_cycles_zero_spec' (latest)
--   agentTrustGraph            → new table: trust_edges (see below, Phase 2 extension)
--   issueLabels                → tasks.labels column
--   preClaimTimestamps         → tasks.claimed_at column


-- =============================================================================
-- EXAMPLE QUERIES for common coordinator operations
-- =============================================================================

-- 1. Atomic task claim (replaces CAS loop on ConfigMap string):
--    BEGIN IMMEDIATE;
--    UPDATE tasks SET state = 'claimed', claimed_by = 'worker-xyz', claimed_at = datetime('now')
--    WHERE issue_number = 1845 AND state = 'queued';
--    SELECT changes(); -- 1 = success, 0 = already claimed
--    COMMIT;

-- 2. Task completion:
--    UPDATE tasks SET state = 'done', completed_at = datetime('now'), pr_number = 1879
--    WHERE issue_number = 1845;

-- 3. Tally votes for a proposal (replaces tally_votes bash loop):
--    SELECT stance, COUNT(*) FROM votes WHERE proposal_id = ? GROUP BY stance;

-- 4. Check if debate thread is resolved:
--    SELECT is_resolved, resolution FROM debates WHERE thread_id = ?
--    AND parent_id IS NULL; -- Root thought determines thread resolution

-- 5. Agent vision score history (replaces scanning Report CRs):
--    SELECT agent_name, vision_score, created_at FROM agent_activity
--    WHERE action_type = 'completed_task' AND agent_name = 'worker-xyz'
--    ORDER BY created_at DESC LIMIT 10;

-- 6. Stale assignment cleanup (replaces coordinator bash cleanup loop):
--    UPDATE tasks SET state = 'queued', claimed_by = NULL, claimed_at = NULL
--    WHERE state = 'claimed'
--      AND claimed_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-2 hours');

-- 7. Routing: find specialized agents for an issue's labels:
--    SELECT DISTINCT agent_name, details FROM agent_activity
--    WHERE action_type = 'completed_task'
--      AND json_extract(details, '$.labels') LIKE '%bug%'
--    ORDER BY created_at DESC LIMIT 10;
