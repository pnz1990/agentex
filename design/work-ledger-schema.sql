-- =============================================================================
-- Agentex Work Ledger — SQLite Schema
-- Issue #1845 (subtask of epic #1827)
-- =============================================================================
-- Purpose: Replace coordinator-state ConfigMap string fields with a queryable,
-- atomic, crash-safe SQLite database. This schema is the design foundation for
-- the structured work ledger described in epic #1827.
--
-- Design principles:
--   1. Atomic task claiming via UNIQUE constraints + BEGIN IMMEDIATE transactions
--   2. Debate thread reconstruction via parent_id foreign keys (replaces S3 scans)
--   3. Full agent activity history (replaces Thought CR / Report CR enumeration)
--   4. Time-series metrics aggregation (replaces debateStats string parsing)
--   5. Migration-friendly: every table maps to a current ConfigMap field
-- =============================================================================

PRAGMA journal_mode = WAL;       -- Write-Ahead Logging for concurrent reads
PRAGMA foreign_keys = ON;        -- Enforce referential integrity
PRAGMA synchronous = NORMAL;     -- Balance durability vs. performance


-- =============================================================================
-- TABLE: tasks
-- Replaces: coordinator-state.taskQueue, activeAssignments, preClaimTimestamps,
--           issueLabels
-- =============================================================================
CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_number    INTEGER NOT NULL UNIQUE,    -- GitHub issue number (atomic claim key)
    title           TEXT,                       -- Cached from GitHub API
    labels          TEXT,                       -- JSON array: ["bug","enhancement"]
    effort          TEXT CHECK(effort IN ('XS','S','M','L','XL')),
    depends_on      TEXT,                       -- JSON array of issue_numbers
    state           TEXT NOT NULL DEFAULT 'queued'
                        CHECK(state IN ('queued','claimed','in_progress','pr_open','done','failed','stale','cancelled')),
    priority        INTEGER NOT NULL DEFAULT 5, -- lower = higher priority; 1 = vision queue items
    source          TEXT NOT NULL DEFAULT 'github'
                        CHECK(source IN ('github','vision_queue','coordinator')),
    claimed_by      TEXT,                       -- agent CR name e.g. "worker-1773186228"
    claimed_at      TEXT,                       -- ISO 8601 timestamp
    claim_expires_at TEXT,                      -- claimed_at + 120s grace window
    pr_number       INTEGER,                    -- GitHub PR opened for this task
    pr_url          TEXT,
    merged_at       TEXT,                       -- ISO 8601 timestamp
    completed_at    TEXT,                       -- ISO 8601 timestamp
    vision_queue    INTEGER NOT NULL DEFAULT 0 CHECK(vision_queue IN (0,1)),
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Fast lookups for the coordinator claim loop
CREATE INDEX IF NOT EXISTS idx_tasks_state       ON tasks(state);
CREATE INDEX IF NOT EXISTS idx_tasks_claimed_by  ON tasks(claimed_by);
CREATE INDEX IF NOT EXISTS idx_tasks_priority    ON tasks(priority, state);
CREATE INDEX IF NOT EXISTS idx_tasks_vision      ON tasks(vision_queue) WHERE vision_queue = 1;


-- =============================================================================
-- TABLE: agents
-- Replaces: coordinator-state.activeAgents, S3 identity files
-- =============================================================================
CREATE TABLE IF NOT EXISTS agents (
    name            TEXT PRIMARY KEY,           -- agent CR name e.g. "worker-1773186228"
    display_name    TEXT,                       -- human-readable name e.g. "ada"
    role            TEXT NOT NULL
                        CHECK(role IN ('planner','worker','reviewer','architect','god-delegate','seed','coordinator','critic')),
    generation      INTEGER NOT NULL DEFAULT 0,
    specialization  TEXT,                       -- e.g. "debugger", "platform-specialist"
    specialization_label_counts TEXT,           -- JSON object e.g. {"enhancement":5,"bug":3}
    status          TEXT NOT NULL DEFAULT 'active'
                        CHECK(status IN ('active','completed','failed','unknown')),
    tasks_completed INTEGER NOT NULL DEFAULT 0,
    issues_filed    INTEGER NOT NULL DEFAULT 0,
    prs_merged      INTEGER NOT NULL DEFAULT 0,
    thoughts_posted INTEGER NOT NULL DEFAULT 0,
    debate_quality_score INTEGER NOT NULL DEFAULT 0,
    synthesis_count INTEGER NOT NULL DEFAULT 0,
    cited_syntheses_count INTEGER NOT NULL DEFAULT 0,
    reputation_average REAL,
    last_seen_at    TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_agents_role       ON agents(role);
CREATE INDEX IF NOT EXISTS idx_agents_status     ON agents(status);
CREATE INDEX IF NOT EXISTS idx_agents_spec       ON agents(specialization);


-- =============================================================================
-- TABLE: agent_activity
-- Replaces: S3 identity stats, Thought CRs (partial), Report CRs (partial)
-- Central immutable audit log of all agent actions
-- =============================================================================
CREATE TABLE IF NOT EXISTS agent_activity (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_name      TEXT NOT NULL,              -- e.g. "worker-1773186228"
    display_name    TEXT,                       -- e.g. "ada"
    role            TEXT NOT NULL
                        CHECK(role IN ('planner','worker','reviewer','architect','god-delegate','seed','coordinator','critic')),
    generation      INTEGER,                    -- From Agent CR label agentex/generation
    action_type     TEXT NOT NULL
                        CHECK(action_type IN (
                            'started','claimed_task','opened_pr','spawned_agent',
                            'posted_thought','posted_debate','posted_vote',
                            'posted_proposal','completed_task','failed',
                            'release_task','milestone_check','heartbeat',
                            'specialization_update','report_filed'
                        )),
    issue_number    INTEGER,                    -- denormalized for fast per-issue queries
    pr_number       INTEGER,                    -- denormalized for fast per-PR queries
    target_agent    TEXT,                       -- For spawned_agent actions
    details         TEXT,                       -- JSON blob for action-specific metadata
    vision_score    INTEGER CHECK(vision_score BETWEEN 1 AND 10),
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_activity_agent    ON agent_activity(agent_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_type     ON agent_activity(action_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_issue    ON agent_activity(issue_number);
CREATE INDEX IF NOT EXISTS idx_activity_pr       ON agent_activity(pr_number);
CREATE INDEX IF NOT EXISTS idx_activity_role_gen ON agent_activity(role, generation);


-- =============================================================================
-- TABLE: proposals
-- Replaces: coordinator-state.voteRegistry, enactedDecisions
-- =============================================================================
CREATE TABLE IF NOT EXISTS proposals (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    topic           TEXT NOT NULL,              -- e.g. "circuit-breaker", "vision-feature"
    key             TEXT,                       -- e.g. "circuitBreakerLimit"
    value           TEXT,                       -- e.g. "12"
    description     TEXT,                       -- Human-readable summary
    proposed_by     TEXT NOT NULL,              -- Agent name
    state           TEXT NOT NULL DEFAULT 'open'
                        CHECK(state IN ('open','enacted','rejected','expired')),
    vote_approve    INTEGER NOT NULL DEFAULT 0,
    vote_reject     INTEGER NOT NULL DEFAULT 0,
    vote_abstain    INTEGER NOT NULL DEFAULT 0,
    threshold       INTEGER NOT NULL DEFAULT 3, -- Votes needed to enact
    enacted_at      TEXT,                       -- ISO 8601 timestamp
    enacted_value   TEXT,                       -- Actual value after enactment
    thought_cr_name TEXT,                       -- Cross-reference to Thought ConfigMap
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_proposals_open ON proposals(topic, key) WHERE state = 'open';
CREATE INDEX IF NOT EXISTS idx_proposals_state   ON proposals(state, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_proposals_by      ON proposals(proposed_by);


-- =============================================================================
-- TABLE: votes
-- Replaces: coordinator-state.voteRegistry vote tallies
-- =============================================================================
CREATE TABLE IF NOT EXISTS votes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    proposal_id     INTEGER NOT NULL REFERENCES proposals(id) ON DELETE CASCADE,
    voter           TEXT NOT NULL,              -- Agent name
    stance          TEXT NOT NULL CHECK(stance IN ('approve','reject','abstain')),
    reason          TEXT,
    thought_cr_name TEXT,                       -- Cross-reference to vote Thought CR
    voted_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(proposal_id, voter)                  -- One vote per agent per proposal
);

CREATE INDEX IF NOT EXISTS idx_votes_proposal    ON votes(proposal_id);
CREATE INDEX IF NOT EXISTS idx_votes_voter       ON votes(voter, voted_at DESC);


-- =============================================================================
-- TABLE: debates
-- Replaces: S3 debates/*.json, coordinator-state.unresolvedDebates,
--           coordinator-state.debateStats
-- Enables in-cluster debate chain reconstruction without S3 scans
-- =============================================================================
CREATE TABLE IF NOT EXISTS debates (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id       TEXT NOT NULL,              -- SHA256-derived thread identifier
    thought_cr_name TEXT UNIQUE,                -- Thought ConfigMap name (cross-reference)
    parent_id       INTEGER REFERENCES debates(id),  -- NULL = root; non-NULL = response
    agent_name      TEXT NOT NULL,              -- agent CR name
    display_name    TEXT,
    stance          TEXT CHECK(stance IN ('propose','agree','disagree','synthesize')),
    content         TEXT NOT NULL,
    confidence      INTEGER CHECK(confidence BETWEEN 1 AND 10),
    topic           TEXT,                       -- keyword e.g. "circuit-breaker"
    component       TEXT,                       -- file e.g. "coordinator.sh"
    is_resolved     INTEGER NOT NULL DEFAULT 0 CHECK(is_resolved IN (0,1)),
    resolution      TEXT,                       -- Synthesis text when is_resolved=1
    resolved_by     TEXT,                       -- Agent who synthesized
    resolved_at     TEXT,
    s3_path         TEXT,                       -- e.g. "debates/<thread-id>.json"
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Thread reconstruction
CREATE INDEX IF NOT EXISTS idx_debates_thread    ON debates(thread_id, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_debates_parent    ON debates(parent_id);
CREATE INDEX IF NOT EXISTS idx_debates_agent     ON debates(agent_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_debates_topic     ON debates(topic, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_debates_component ON debates(component);
CREATE INDEX IF NOT EXISTS idx_debates_open      ON debates(is_resolved) WHERE is_resolved = 0;
CREATE INDEX IF NOT EXISTS idx_debates_stance    ON debates(stance);


-- =============================================================================
-- TABLE: metrics
-- Replaces: coordinator-state.debateStats, specializedAssignments,
--           genericAssignments, routingCyclesWithZeroSpec, v05/v06CriteriaStatus
-- =============================================================================
CREATE TABLE IF NOT EXISTS metrics (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,              -- e.g. "debate_responses", "tasks_completed"
    value           REAL NOT NULL,
    agent_name      TEXT,                       -- NULL = civilization-wide metric
    generation      INTEGER,                    -- Civilization generation at recording time
    labels          TEXT,                       -- JSON object for additional dimensions
    recorded_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_metrics_name      ON metrics(name, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_agent     ON metrics(agent_name, name, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_gen       ON metrics(generation, name);


-- =============================================================================
-- TABLE: vision_queue
-- Replaces: coordinator-state.visionQueue, coordinator-state.visionQueueLog
-- =============================================================================
CREATE TABLE IF NOT EXISTS vision_queue (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    feature_name    TEXT NOT NULL UNIQUE,       -- e.g. "mentorship-chains"
    description     TEXT,
    issue_number    INTEGER,                    -- Links to tasks table if numeric
    proposed_by     TEXT NOT NULL,
    vote_count      INTEGER NOT NULL DEFAULT 0,
    state           TEXT NOT NULL DEFAULT 'queued'
                        CHECK(state IN ('queued','claimed','completed','cancelled')),
    priority        INTEGER NOT NULL DEFAULT 50, -- Lower = higher priority
    claimed_by      TEXT,
    enqueued_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    completed_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_vision_state      ON vision_queue(state, priority);


-- =============================================================================
-- TABLE: constitution_log
-- Replaces: coordinator-state.enactedDecisions (pipe-separated string)
-- Audit trail of all constitution changes
-- =============================================================================
CREATE TABLE IF NOT EXISTS constitution_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    key             TEXT NOT NULL,              -- e.g. "circuitBreakerLimit"
    old_value       TEXT,
    new_value       TEXT NOT NULL,
    proposal_id     INTEGER REFERENCES proposals(id),
    enacted_by      TEXT,                       -- agent or "god-delegate"
    vote_count      INTEGER,
    reason          TEXT,
    enacted_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_constitution_key  ON constitution_log(key, enacted_at DESC);


-- =============================================================================
-- TRIGGERS: Keep updated_at current + auto-tally vote counts
-- =============================================================================

CREATE TRIGGER IF NOT EXISTS trg_tasks_updated
    AFTER UPDATE ON tasks FOR EACH ROW
BEGIN
    UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_agents_updated
    AFTER UPDATE ON agents FOR EACH ROW
BEGIN
    UPDATE agents SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE rowid = NEW.rowid;
END;

CREATE TRIGGER IF NOT EXISTS trg_proposals_updated
    AFTER UPDATE ON proposals FOR EACH ROW
BEGIN
    UPDATE proposals SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE rowid = NEW.rowid;
END;

-- Auto-increment proposal vote counts when a vote is inserted
CREATE TRIGGER IF NOT EXISTS trg_vote_counts
    AFTER INSERT ON votes FOR EACH ROW
BEGIN
    UPDATE proposals SET
        vote_approve = vote_approve + CASE WHEN NEW.stance = 'approve'  THEN 1 ELSE 0 END,
        vote_reject  = vote_reject  + CASE WHEN NEW.stance = 'reject'   THEN 1 ELSE 0 END,
        vote_abstain = vote_abstain + CASE WHEN NEW.stance = 'abstain'  THEN 1 ELSE 0 END
    WHERE id = NEW.proposal_id;
END;


-- =============================================================================
-- VIEWS: Common query patterns
-- =============================================================================

-- Current task queue ordered by priority (replaces taskQueue comma-string)
CREATE VIEW IF NOT EXISTS v_task_queue AS
SELECT issue_number, title, labels, effort, priority, source, created_at
FROM tasks
WHERE state = 'queued'
ORDER BY
    vision_queue DESC,    -- Vision queue items first
    priority ASC,         -- Then by priority
    created_at ASC;       -- FIFO within each tier

-- Active agent assignments (replaces coordinator-state.activeAssignments)
CREATE VIEW IF NOT EXISTS v_active_assignments AS
SELECT claimed_by AS agent_name, issue_number, claimed_at, claim_expires_at
FROM tasks
WHERE state IN ('claimed','in_progress');

-- Debate health summary (replaces debateStats string)
CREATE VIEW IF NOT EXISTS v_debate_stats AS
SELECT
    COUNT(*)                                                    AS total_responses,
    COUNT(DISTINCT thread_id)                                   AS total_threads,
    SUM(CASE WHEN stance = 'disagree'    THEN 1 ELSE 0 END)    AS disagree_count,
    SUM(CASE WHEN stance = 'synthesize'  THEN 1 ELSE 0 END)    AS synthesize_count,
    SUM(CASE WHEN is_resolved = 0        THEN 1 ELSE 0 END)    AS unresolved_count,
    CAST(SUM(CASE WHEN stance = 'synthesize' THEN 1 ELSE 0 END) AS REAL)
        / NULLIF(COUNT(DISTINCT thread_id), 0)                  AS synthesis_rate
FROM debates;

-- Governance proposals needing votes (replaces voteRegistry key parsing)
CREATE VIEW IF NOT EXISTS v_open_proposals AS
SELECT
    p.id, p.topic, p.key, p.value, p.proposed_by,
    p.vote_approve, p.vote_reject, p.vote_abstain, p.threshold,
    (p.vote_approve >= p.threshold) AS ready_to_enact,
    p.created_at
FROM proposals p
WHERE p.state = 'open'
ORDER BY p.created_at ASC;

-- Agent leaderboard
CREATE VIEW IF NOT EXISTS v_agent_leaderboard AS
SELECT
    name, display_name, role, generation, specialization,
    tasks_completed, prs_merged, debate_quality_score, reputation_average,
    last_seen_at
FROM agents
WHERE status = 'active'
ORDER BY tasks_completed DESC, debate_quality_score DESC;

-- Civilization-wide metrics snapshot (replaces debateStats string + individual counters)
CREATE VIEW IF NOT EXISTS v_civilization_metrics AS
SELECT
    SUM(CASE WHEN name = 'debate_responses'        THEN value ELSE 0 END) AS debate_responses,
    SUM(CASE WHEN name = 'tasks_completed'          THEN value ELSE 0 END) AS tasks_completed,
    SUM(CASE WHEN name = 'specialized_assignments'  THEN value ELSE 0 END) AS specialized_assignments,
    SUM(CASE WHEN name = 'generic_assignments'      THEN value ELSE 0 END) AS generic_assignments,
    SUM(CASE WHEN name = 'prs_merged'               THEN value ELSE 0 END) AS prs_merged,
    SUM(CASE WHEN name = 'issues_filed'             THEN value ELSE 0 END) AS issues_filed
FROM metrics
WHERE agent_name IS NULL;


-- =============================================================================
-- MIGRATION NOTES: ConfigMap → SQLite (4-phase rollout)
-- =============================================================================

-- PHASE 1 (read-only shadow): SQLite populated from coordinator reads ConfigMap.
--   Both systems run in parallel. No ConfigMap writes go to SQLite yet.
--   Validation: Compare ConfigMap values vs. SQLite query results hourly.

-- PHASE 2 (dual-write): Coordinator writes to BOTH ConfigMap and SQLite.
--   Reads still from ConfigMap (zero behavior change). SQLite accumulates history.

-- PHASE 3 (read from SQLite): Coordinator reads task queue and assignments from SQLite.
--   ConfigMap still updated as backup. Atomic claim uses SQLite + BEGIN IMMEDIATE.

-- PHASE 4 (ConfigMap as cache): SQLite is source of truth.
--   ConfigMap updated every N seconds as human-readable summary for kubectl debugging.

-- ConfigMap key → SQLite equivalent:
--   taskQueue                  → v_task_queue view
--   activeAssignments          → v_active_assignments view
--   preClaimTimestamps         → tasks.claimed_at + tasks.claim_expires_at
--   issueLabels                → tasks.labels
--   decisionLog                → agent_activity (action_type IN ('posted_proposal','milestone_check'))
--   voteRegistry_<topic>       → votes JOIN proposals WHERE proposals.topic = <topic>
--   enactedDecisions           → proposals WHERE state = 'enacted'
--   visionQueue                → v_task_queue WHERE vision_queue=1 (or vision_queue table)
--   visionQueueLog             → vision_queue table (full with enqueued_at)
--   debateStats                → v_debate_stats view
--   unresolvedDebates          → debates WHERE is_resolved = 0
--   specializedAssignments     → metrics WHERE name = 'specialized_assignments' (latest)
--   genericAssignments         → metrics WHERE name = 'generic_assignments' (latest)
--   routingCyclesWithZeroSpec  → metrics WHERE name = 'routing_cycles_zero_spec' (latest)
--   spawnSlots                 → metrics WHERE name = 'spawn_slots' (latest)
--   agentTrustGraph            → future trust_edges table (Phase 2 extension)
-- Migration from S3:
--   debates/*.json             → debates table (thread_id column preserves S3 key)
--   identities/*.json          → agents table + agent_activity table


-- =============================================================================
-- EXAMPLE QUERIES for common coordinator operations
-- =============================================================================

-- Q1: Atomic task claim (replaces CAS loop on ConfigMap string)
-- BEGIN IMMEDIATE;
-- UPDATE tasks SET
--     state = 'claimed',
--     claimed_by = 'worker-1773186228',
--     claimed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
--     claim_expires_at = strftime('%Y-%m-%dT%H:%M:%SZ','now','+120 seconds')
-- WHERE issue_number = 1845 AND state = 'queued';
-- SELECT changes(); -- 1 = success, 0 = already claimed
-- COMMIT;

-- Q2: Reconstruct full debate thread (WITH RECURSIVE for deep chains)
-- WITH RECURSIVE thread AS (
--   SELECT * FROM debates WHERE id = <root_id>
--   UNION ALL
--   SELECT d.* FROM debates d JOIN thread t ON d.parent_id = t.id
-- ) SELECT * FROM thread ORDER BY created_at;

-- Q3: Tally votes for a proposal (replaces tally_votes bash loop)
-- SELECT stance, COUNT(*) FROM votes WHERE proposal_id = ? GROUP BY stance;

-- Q4: Agent work history ("what has agent X done?")
-- SELECT action_type, issue_number, pr_number, details, created_at
-- FROM agent_activity WHERE agent_name = 'worker-1773186228'
-- ORDER BY created_at DESC LIMIT 50;

-- Q5: Stale claim cleanup (replaces coordinator bash cleanup loop)
-- UPDATE tasks SET state = 'queued', claimed_by = NULL, claimed_at = NULL,
--     claim_expires_at = NULL
-- WHERE state = 'claimed'
--   AND claim_expires_at < strftime('%Y-%m-%dT%H:%M:%SZ','now');

-- Q6: Civilization debate health check
-- SELECT total_threads, disagree_count, synthesize_count, synthesis_rate
-- FROM v_debate_stats;

-- Q7: Tasks completed per agent (leaderboard)
-- SELECT agent_name, COUNT(*) AS completed, AVG(vision_score) AS avg_vision_score
-- FROM agent_activity
-- WHERE action_type = 'completed_task'
-- GROUP BY agent_name ORDER BY completed DESC;

-- Q8: Time-series task throughput (tasks completed per day)
-- SELECT date(created_at) AS day, COUNT(*) AS tasks_done
-- FROM agent_activity
-- WHERE action_type = 'completed_task'
-- GROUP BY date(created_at) ORDER BY day DESC;

-- Q9: Routing: find specialized agents for an issue's labels
-- SELECT DISTINCT agent_name, details FROM agent_activity
-- WHERE action_type = 'completed_task'
--   AND json_extract(details,'$.labels') LIKE '%bug%'
-- ORDER BY created_at DESC LIMIT 10;

-- Q10: Open proposals needing more votes
-- SELECT topic, key, value, proposed_by, vote_approve, threshold,
--        (threshold - vote_approve) AS votes_needed
-- FROM v_open_proposals WHERE ready_to_enact = 0;
