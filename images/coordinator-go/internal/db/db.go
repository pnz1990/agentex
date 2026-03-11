// Package db provides SQLite database initialization and schema management
// for the agentex Go coordinator rewrite (issue #1825, #1827).
package db

import (
	"database/sql"
	"fmt"

	_ "github.com/mattn/go-sqlite3"
)

// DB wraps a *sql.DB with coordinator-specific helpers.
type DB struct {
	*sql.DB
}

// Open opens (or creates) the SQLite database at path and applies the schema.
func Open(path string) (*DB, error) {
	sqlDB, err := sql.Open("sqlite3", path+"?_journal_mode=WAL&_foreign_keys=on")
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}

	db := &DB{sqlDB}
	if err := db.applySchema(); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return db, nil
}

// Ping verifies the database is reachable.
func (db *DB) Ping() error {
	return db.DB.Ping()
}

// applySchema creates all tables, indexes, triggers, and compatibility views.
func (db *DB) applySchema() error {
	_, err := db.Exec(schema)
	return err
}

// schema is the full SQLite DDL for the coordinator work ledger.
// Designed to replace coordinator-state ConfigMap string fields with
// typed, queryable relational data (issue #1827).
const schema = `
-- Tasks (replaces coordinator-state.taskQueue + activeAssignments)
CREATE TABLE IF NOT EXISTS tasks (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_number INTEGER NOT NULL,
    title        TEXT    NOT NULL,
    status       TEXT    NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending','assigned','in_progress','done','failed')),
    assigned_to  TEXT    NOT NULL DEFAULT '',
    priority     INTEGER NOT NULL DEFAULT 0,
    labels       TEXT    NOT NULL DEFAULT '',
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    claimed_at   DATETIME,
    completed_at DATETIME
);

CREATE INDEX IF NOT EXISTS idx_tasks_status        ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_issue_number  ON tasks(issue_number);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to   ON tasks(assigned_to);
CREATE INDEX IF NOT EXISTS idx_tasks_priority      ON tasks(priority DESC);

-- Agents (replaces coordinator-state.activeAgents + S3 identity files)
CREATE TABLE IF NOT EXISTS agents (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT    NOT NULL UNIQUE,
    display_name    TEXT    NOT NULL DEFAULT '',
    role            TEXT    NOT NULL
                            CHECK (role IN ('planner','worker','reviewer','architect','god-delegate','seed')),
    generation      INTEGER NOT NULL DEFAULT 0,
    specialization  TEXT    NOT NULL DEFAULT '',
    status          TEXT    NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active','completed','failed')),
    started_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at    DATETIME
);

CREATE INDEX IF NOT EXISTS idx_agents_role         ON agents(role);
CREATE INDEX IF NOT EXISTS idx_agents_status       ON agents(status);
CREATE INDEX IF NOT EXISTS idx_agents_generation   ON agents(generation);

-- Thoughts (in-cluster Thought CR mirror for querying)
CREATE TABLE IF NOT EXISTS thoughts (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL UNIQUE,
    agent_ref    TEXT    NOT NULL,
    task_ref     TEXT    NOT NULL DEFAULT '',
    thought_type TEXT    NOT NULL
                         CHECK (thought_type IN ('insight','proposal','vote','debate','directive','blocker','planning','chronicle-candidate','report')),
    confidence   INTEGER NOT NULL DEFAULT 5 CHECK (confidence BETWEEN 1 AND 10),
    content      TEXT    NOT NULL,
    parent_ref   TEXT    NOT NULL DEFAULT '',
    topic        TEXT    NOT NULL DEFAULT '',
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_thoughts_agent_ref    ON thoughts(agent_ref);
CREATE INDEX IF NOT EXISTS idx_thoughts_thought_type ON thoughts(thought_type);
CREATE INDEX IF NOT EXISTS idx_thoughts_topic        ON thoughts(topic);
CREATE INDEX IF NOT EXISTS idx_thoughts_parent_ref   ON thoughts(parent_ref);
CREATE INDEX IF NOT EXISTS idx_thoughts_created_at   ON thoughts(created_at DESC);

-- Debate outcomes (replaces S3 debates/ prefix)
CREATE TABLE IF NOT EXISTS debate_outcomes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id    TEXT    NOT NULL UNIQUE,
    topic        TEXT    NOT NULL,
    outcome      TEXT    NOT NULL
                         CHECK (outcome IN ('synthesized','consensus-agree','consensus-disagree','unresolved')),
    resolution   TEXT    NOT NULL,
    participants TEXT    NOT NULL DEFAULT '[]',
    recorded_by  TEXT    NOT NULL,
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_debate_outcomes_topic   ON debate_outcomes(topic);
CREATE INDEX IF NOT EXISTS idx_debate_outcomes_outcome ON debate_outcomes(outcome);

-- Governance proposals and votes (replaces coordinator-state.voteRegistry)
CREATE TABLE IF NOT EXISTS governance_proposals (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    proposal_id   TEXT    NOT NULL UNIQUE,
    topic         TEXT    NOT NULL,
    agent_ref     TEXT    NOT NULL,
    content       TEXT    NOT NULL,
    status        TEXT    NOT NULL DEFAULT 'open'
                          CHECK (status IN ('open','enacted','rejected')),
    approve_count INTEGER NOT NULL DEFAULT 0,
    reject_count  INTEGER NOT NULL DEFAULT 0,
    created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    enacted_at    DATETIME
);

CREATE TABLE IF NOT EXISTS governance_votes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    proposal_id TEXT    NOT NULL REFERENCES governance_proposals(proposal_id),
    agent_ref   TEXT    NOT NULL,
    vote        TEXT    NOT NULL CHECK (vote IN ('approve','reject','abstain')),
    reason      TEXT    NOT NULL DEFAULT '',
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (proposal_id, agent_ref)
);

CREATE INDEX IF NOT EXISTS idx_governance_votes_proposal ON governance_votes(proposal_id);

-- Spawn slots (replaces coordinator-state.spawnSlots CAS logic)
CREATE TABLE IF NOT EXISTS spawn_slots (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_name   TEXT    NOT NULL,
    allocated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    released_at  DATETIME
);

CREATE INDEX IF NOT EXISTS idx_spawn_slots_released ON spawn_slots(released_at);

-- Planning state (replaces S3 planning/ prefix for N+2 coordination)
CREATE TABLE IF NOT EXISTS planning_states (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    role        TEXT    NOT NULL,
    agent_name  TEXT    NOT NULL,
    generation  INTEGER NOT NULL,
    my_work     TEXT    NOT NULL DEFAULT '',
    n1_priority TEXT    NOT NULL DEFAULT '',
    n2_priority TEXT    NOT NULL DEFAULT '',
    blockers    TEXT    NOT NULL DEFAULT '',
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_planning_states_generation ON planning_states(generation DESC);
CREATE INDEX IF NOT EXISTS idx_planning_states_role       ON planning_states(role);

-- Triggers: auto-update updated_at on tasks
CREATE TRIGGER IF NOT EXISTS tasks_updated_at
    AFTER UPDATE ON tasks
    FOR EACH ROW
BEGIN
    UPDATE tasks SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- Compatibility views (allow coordinator shell to query via sqlite3 CLI)
CREATE VIEW IF NOT EXISTS active_agents AS
    SELECT name, display_name, role, generation, specialization, last_seen_at
    FROM agents
    WHERE status = 'active';

CREATE VIEW IF NOT EXISTS pending_tasks AS
    SELECT id, issue_number, title, priority, labels, created_at
    FROM tasks
    WHERE status = 'pending'
    ORDER BY priority DESC, created_at ASC;

CREATE VIEW IF NOT EXISTS active_assignments AS
    SELECT assigned_to, issue_number, title, claimed_at
    FROM tasks
    WHERE status IN ('assigned','in_progress') AND assigned_to != '';

CREATE VIEW IF NOT EXISTS open_proposals AS
    SELECT proposal_id, topic, agent_ref, approve_count, reject_count, created_at
    FROM governance_proposals
    WHERE status = 'open'
    ORDER BY created_at DESC;

CREATE VIEW IF NOT EXISTS debate_backlog AS
    SELECT t.name, t.agent_ref, t.topic, t.created_at
    FROM thoughts t
    WHERE t.thought_type = 'debate'
      AND t.name NOT IN (SELECT 'thought-' || thread_id FROM debate_outcomes);

CREATE VIEW IF NOT EXISTS recent_insights AS
    SELECT name, agent_ref, confidence, topic, content, created_at
    FROM thoughts
    WHERE thought_type = 'insight'
    ORDER BY created_at DESC
    LIMIT 50;
`
