// Package db handles SQLite database initialization and migrations for the
// agentex Go coordinator. This replaces coordinator-state ConfigMap string
// fields with a queryable, atomic, crash-safe SQLite database.
//
// See design/work-ledger-schema.sql for the full schema design (issue #1845,
// part of epic #1827).
package db

import (
	"database/sql"
	"fmt"
	"log"
	"os"

	_ "github.com/mattn/go-sqlite3"
)

// DB wraps a *sql.DB with agentex-specific helpers.
type DB struct {
	*sql.DB
}

// Open opens (or creates) the SQLite database at the given path and applies
// the schema migrations.
func Open(path string) (*DB, error) {
	// Ensure parent directory exists.
	if dir := dbDir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("create db dir: %w", err)
		}
	}

	dsn := path + "?_journal=WAL&_foreign_keys=on&_synchronous=NORMAL"
	sqlDB, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}

	// SQLite only allows one writer at a time; a pool of 1 avoids "database is locked" errors.
	sqlDB.SetMaxOpenConns(1)

	db := &DB{sqlDB}
	if err := db.migrate(); err != nil {
		_ = sqlDB.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}

	log.Printf("[coordinator-db] opened %s", path)
	return db, nil
}

// migrate applies all schema migrations idempotently.
func (db *DB) migrate() error {
	if _, err := db.Exec(schema); err != nil {
		return fmt.Errorf("apply schema: %w", err)
	}
	return nil
}

// dbDir returns the directory portion of path, or "" if path has no directory.
func dbDir(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return ""
}

// schema is the idempotent DDL for all work-ledger tables.
// Based on design/work-ledger-schema.sql (issue #1845 / epic #1827).
const schema = `
-- ============================================================
-- Agentex Work Ledger — SQLite Schema
-- Ref: design/work-ledger-schema.sql (issue #1845, epic #1827)
-- ============================================================

-- tasks: replaces coordinator-state.taskQueue + activeAssignments
CREATE TABLE IF NOT EXISTS tasks (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_number     INTEGER NOT NULL UNIQUE,
    title            TEXT,
    labels           TEXT,        -- JSON array
    effort           TEXT CHECK(effort IN ('XS','S','M','L','XL')),
    depends_on       TEXT,        -- JSON array of issue_numbers
    state            TEXT NOT NULL DEFAULT 'queued'
                         CHECK(state IN ('queued','claimed','in_progress','pr_open','done','failed','stale','cancelled')),
    priority         INTEGER NOT NULL DEFAULT 5,
    source           TEXT NOT NULL DEFAULT 'github'
                         CHECK(source IN ('github','vision_queue','coordinator')),
    claimed_by       TEXT,
    claimed_at       TEXT,
    claim_expires_at TEXT,
    pr_number        INTEGER,
    pr_url           TEXT,
    merged_at        TEXT,
    completed_at     TEXT,
    vision_queue     INTEGER NOT NULL DEFAULT 0 CHECK(vision_queue IN (0,1)),
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_state      ON tasks(state);
CREATE INDEX IF NOT EXISTS idx_tasks_claimed_by ON tasks(claimed_by);
CREATE INDEX IF NOT EXISTS idx_tasks_priority   ON tasks(priority, state);
CREATE INDEX IF NOT EXISTS idx_tasks_vision     ON tasks(vision_queue) WHERE vision_queue = 1;

-- agents: replaces coordinator-state.activeAgents + S3 identity files
CREATE TABLE IF NOT EXISTS agents (
    name                         TEXT PRIMARY KEY,
    display_name                 TEXT,
    role                         TEXT NOT NULL
                                     CHECK(role IN ('planner','worker','reviewer','architect',
                                                    'god-delegate','seed','coordinator','critic')),
    generation                   INTEGER NOT NULL DEFAULT 0,
    specialization               TEXT,
    specialization_label_counts  TEXT,   -- JSON object
    status                       TEXT NOT NULL DEFAULT 'active'
                                     CHECK(status IN ('active','completed','failed','unknown')),
    tasks_completed              INTEGER NOT NULL DEFAULT 0,
    issues_filed                 INTEGER NOT NULL DEFAULT 0,
    prs_merged                   INTEGER NOT NULL DEFAULT 0,
    thoughts_posted              INTEGER NOT NULL DEFAULT 0,
    debate_quality_score         INTEGER NOT NULL DEFAULT 0,
    synthesis_count              INTEGER NOT NULL DEFAULT 0,
    cited_syntheses_count        INTEGER NOT NULL DEFAULT 0,
    reputation_average           REAL,
    last_seen_at                 TEXT,
    created_at                   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at                   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_agents_role   ON agents(role);
CREATE INDEX IF NOT EXISTS idx_agents_status ON agents(status);
CREATE INDEX IF NOT EXISTS idx_agents_spec   ON agents(specialization);

-- agent_activity: immutable audit log; replaces Thought/Report CRs + S3 stats
CREATE TABLE IF NOT EXISTS agent_activity (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_name   TEXT NOT NULL,
    display_name TEXT,
    role         TEXT NOT NULL
                     CHECK(role IN ('planner','worker','reviewer','architect',
                                    'god-delegate','seed','coordinator','critic')),
    generation   INTEGER,
    action_type  TEXT NOT NULL
                     CHECK(action_type IN (
                         'started','claimed_task','opened_pr','spawned_agent',
                         'posted_thought','posted_debate','posted_vote',
                         'posted_proposal','completed_task','failed',
                         'release_task','milestone_check','heartbeat',
                         'specialization_update','report_filed'
                     )),
    issue_number INTEGER,
    pr_number    INTEGER,
    target_agent TEXT,
    details      TEXT,   -- JSON blob
    vision_score INTEGER CHECK(vision_score BETWEEN 1 AND 10),
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_activity_agent    ON agent_activity(agent_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_type     ON agent_activity(action_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_issue    ON agent_activity(issue_number);
CREATE INDEX IF NOT EXISTS idx_activity_pr       ON agent_activity(pr_number);
CREATE INDEX IF NOT EXISTS idx_activity_role_gen ON agent_activity(role, generation);

-- proposals: replaces voteRegistry + enactedDecisions
CREATE TABLE IF NOT EXISTS proposals (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    topic          TEXT NOT NULL,
    key            TEXT,
    value          TEXT,
    description    TEXT,
    proposed_by    TEXT NOT NULL,
    state          TEXT NOT NULL DEFAULT 'open'
                       CHECK(state IN ('open','enacted','rejected','expired')),
    vote_approve   INTEGER NOT NULL DEFAULT 0,
    vote_reject    INTEGER NOT NULL DEFAULT 0,
    vote_abstain   INTEGER NOT NULL DEFAULT 0,
    threshold      INTEGER NOT NULL DEFAULT 3,
    enacted_at     TEXT,
    enacted_value  TEXT,
    thought_cr_name TEXT,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_proposals_open  ON proposals(topic, key) WHERE state = 'open';
CREATE INDEX        IF NOT EXISTS idx_proposals_state ON proposals(state, created_at DESC);
CREATE INDEX        IF NOT EXISTS idx_proposals_by    ON proposals(proposed_by);

-- votes: replaces voteRegistry vote tallies
CREATE TABLE IF NOT EXISTS votes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    proposal_id     INTEGER NOT NULL REFERENCES proposals(id) ON DELETE CASCADE,
    voter           TEXT NOT NULL,
    stance          TEXT NOT NULL CHECK(stance IN ('approve','reject','abstain')),
    reason          TEXT,
    thought_cr_name TEXT,
    voted_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(proposal_id, voter)
);

CREATE INDEX IF NOT EXISTS idx_votes_proposal ON votes(proposal_id);
CREATE INDEX IF NOT EXISTS idx_votes_voter    ON votes(voter, voted_at DESC);

-- debates: replaces S3 debates/*.json + unresolvedDebates + debateStats
CREATE TABLE IF NOT EXISTS debates (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id       TEXT NOT NULL,
    thought_cr_name TEXT UNIQUE,
    parent_id       INTEGER REFERENCES debates(id),
    agent_name      TEXT NOT NULL,
    display_name    TEXT,
    stance          TEXT CHECK(stance IN ('propose','agree','disagree','synthesize')),
    content         TEXT NOT NULL,
    confidence      INTEGER CHECK(confidence BETWEEN 1 AND 10),
    topic           TEXT,
    component       TEXT,
    is_resolved     INTEGER NOT NULL DEFAULT 0 CHECK(is_resolved IN (0,1)),
    resolution      TEXT,
    resolved_by     TEXT,
    resolved_at     TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_debates_thread    ON debates(thread_id, created_at);
CREATE INDEX IF NOT EXISTS idx_debates_agent     ON debates(agent_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_debates_parent    ON debates(parent_id);
CREATE INDEX IF NOT EXISTS idx_debates_topic     ON debates(topic);
CREATE INDEX IF NOT EXISTS idx_debates_unresolved ON debates(is_resolved) WHERE is_resolved = 0;

-- metrics: replaces debateStats string + specializedAssignments + other counters
CREATE TABLE IF NOT EXISTS metrics (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    metric      TEXT NOT NULL,
    value       INTEGER NOT NULL,
    agent       TEXT,
    labels      TEXT,   -- JSON object for dimensions
    recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_metrics_name   ON metrics(metric, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_agent  ON metrics(agent, metric);

-- vision_queue: replaces coordinator-state.visionQueue + visionQueueLog
CREATE TABLE IF NOT EXISTS vision_queue (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    feature_name TEXT NOT NULL,
    description  TEXT,
    issue_number INTEGER,
    proposed_by  TEXT NOT NULL,
    vote_count   INTEGER NOT NULL DEFAULT 0,
    state        TEXT NOT NULL DEFAULT 'active'
                     CHECK(state IN ('active','claimed','done','cancelled')),
    claimed_by   TEXT,
    claimed_at   TEXT,
    enacted_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_vision_queue_feature ON vision_queue(feature_name) WHERE state = 'active';
CREATE INDEX        IF NOT EXISTS idx_vision_queue_state   ON vision_queue(state, enacted_at);

-- constitution_log: replaces enactedDecisions string
CREATE TABLE IF NOT EXISTS constitution_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    key        TEXT NOT NULL,
    old_value  TEXT,
    new_value  TEXT NOT NULL,
    reason     TEXT,
    enacted_by TEXT NOT NULL,
    vote_count INTEGER NOT NULL DEFAULT 0,
    enacted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_constitution_log_key ON constitution_log(key, enacted_at DESC);

-- ============================================================
-- TRIGGERS: keep updated_at current
-- ============================================================

CREATE TRIGGER IF NOT EXISTS trg_tasks_updated_at
AFTER UPDATE ON tasks
BEGIN
    UPDATE tasks SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_agents_updated_at
AFTER UPDATE ON agents
BEGIN
    UPDATE agents SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE name = NEW.name;
END;

CREATE TRIGGER IF NOT EXISTS trg_proposals_updated_at
AFTER UPDATE ON proposals
BEGIN
    UPDATE proposals SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_proposals_vote_count
AFTER INSERT ON votes
BEGIN
    UPDATE proposals
    SET vote_approve = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'approve'),
        vote_reject  = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'reject'),
        vote_abstain = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'abstain'),
        updated_at   = strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE id = NEW.proposal_id;
END;

-- ============================================================
-- VIEWS: compatibility shims for coordinator-state fields
-- ============================================================

CREATE VIEW IF NOT EXISTS v_task_queue AS
SELECT issue_number, title, labels, effort, priority, source
FROM   tasks
WHERE  state = 'queued'
ORDER  BY priority ASC, created_at ASC;

CREATE VIEW IF NOT EXISTS v_active_assignments AS
SELECT issue_number, claimed_by, claimed_at, claim_expires_at
FROM   tasks
WHERE  state IN ('claimed','in_progress')
  AND  claim_expires_at > strftime('%Y-%m-%dT%H:%M:%SZ','now');

CREATE VIEW IF NOT EXISTS v_debate_stats AS
SELECT
    COUNT(*)                                                      AS total_responses,
    COUNT(DISTINCT thread_id)                                     AS total_threads,
    SUM(CASE WHEN stance = 'disagree'   THEN 1 ELSE 0 END)       AS disagree_count,
    SUM(CASE WHEN stance = 'synthesize' THEN 1 ELSE 0 END)       AS synthesize_count,
    SUM(CASE WHEN is_resolved = 0       THEN 1 ELSE 0 END)       AS unresolved_count
FROM debates;

CREATE VIEW IF NOT EXISTS v_open_proposals AS
SELECT id, topic, key, value, description, proposed_by,
       vote_approve, vote_reject, vote_abstain, threshold,
       (vote_approve >= threshold) AS ready_to_enact,
       created_at
FROM   proposals
WHERE  state = 'open'
ORDER  BY created_at DESC;

CREATE VIEW IF NOT EXISTS v_agent_leaderboard AS
SELECT name, display_name, role, specialization,
       tasks_completed, prs_merged, synthesis_count,
       cited_syntheses_count, debate_quality_score, reputation_average
FROM   agents
WHERE  status IN ('active','completed')
ORDER  BY tasks_completed DESC, debate_quality_score DESC;

CREATE VIEW IF NOT EXISTS v_civilization_metrics AS
SELECT metric, SUM(value) AS total, MAX(recorded_at) AS last_recorded_at
FROM   metrics
GROUP  BY metric
ORDER  BY metric;
`
