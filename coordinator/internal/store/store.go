// Package store implements the SQLite persistence layer for the coordinator.
// This replaces ConfigMap string-based state with a proper relational database.
//
// Why SQLite:
//   - Single binary, no external database process
//   - WAL mode enables concurrent reads with single writer
//   - Survives pod restarts via PersistentVolume
//   - ACID transactions eliminate ConfigMap CAS race conditions
//   - Full SQL query support for debate history, vote tallying, etc.
package store

import (
	"database/sql"
	"fmt"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/pnz1990/agentex/coordinator/pkg/types"
)

// Store is the main database access object.
// All public methods are safe for concurrent use.
type Store struct {
	db *sql.DB
	mu sync.RWMutex // protects operations requiring atomicity beyond SQL transactions
}

// Open creates or opens the SQLite database at the given path.
// It runs all migrations to bring the schema up to date.
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", fmt.Sprintf("%s?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=on", path))
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}

	// SQLite performs best with a single writer connection
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

// Close closes the database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// migrate runs all schema migrations in order.
// Each migration is idempotent (uses CREATE TABLE IF NOT EXISTS).
func (s *Store) migrate() error {
	migrations := []string{
		createTasksTable,
		createAgentsTable,
		createVotesTable,
		createProposalsTable,
		createDebateOutcomesTable,
		createSpawnSlotsTable,
		createConfigTable,
	}

	for i, m := range migrations {
		if _, err := s.db.Exec(m); err != nil {
			return fmt.Errorf("migration %d: %w", i, err)
		}
	}
	return nil
}

const createTasksTable = `
CREATE TABLE IF NOT EXISTS tasks (
	id           INTEGER PRIMARY KEY AUTOINCREMENT,
	issue_number INTEGER NOT NULL UNIQUE,
	title        TEXT NOT NULL,
	labels       TEXT NOT NULL DEFAULT '',
	priority     INTEGER NOT NULL DEFAULT 0,
	status       TEXT NOT NULL DEFAULT 'pending',
	agent_name   TEXT NOT NULL DEFAULT '',
	claimed_at   DATETIME,
	completed_at DATETIME,
	created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	updated_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority DESC);
`

const createAgentsTable = `
CREATE TABLE IF NOT EXISTS agents (
	id              INTEGER PRIMARY KEY AUTOINCREMENT,
	name            TEXT NOT NULL UNIQUE,
	role            TEXT NOT NULL,
	generation      INTEGER NOT NULL DEFAULT 0,
	display_name    TEXT NOT NULL DEFAULT '',
	specialization  TEXT NOT NULL DEFAULT '',
	registered_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	active          BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX IF NOT EXISTS idx_agents_active ON agents(active);
CREATE INDEX IF NOT EXISTS idx_agents_role ON agents(role);
`

const createVotesTable = `
CREATE TABLE IF NOT EXISTS votes (
	id          INTEGER PRIMARY KEY AUTOINCREMENT,
	topic       TEXT NOT NULL,
	proposal_id TEXT NOT NULL,
	agent_name  TEXT NOT NULL,
	status      TEXT NOT NULL, -- approve|reject|abstain
	value       TEXT NOT NULL DEFAULT '',
	reason      TEXT NOT NULL DEFAULT '',
	created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	UNIQUE(topic, agent_name) -- one vote per agent per topic
);
CREATE INDEX IF NOT EXISTS idx_votes_topic ON votes(topic);
`

const createProposalsTable = `
CREATE TABLE IF NOT EXISTS proposals (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	topic      TEXT NOT NULL,
	agent_name TEXT NOT NULL,
	content    TEXT NOT NULL,
	key        TEXT NOT NULL DEFAULT '',
	value      TEXT NOT NULL DEFAULT '',
	enacted    BOOLEAN NOT NULL DEFAULT FALSE,
	enacted_at DATETIME,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_proposals_topic ON proposals(topic);
CREATE INDEX IF NOT EXISTS idx_proposals_enacted ON proposals(enacted);
`

const createDebateOutcomesTable = `
CREATE TABLE IF NOT EXISTS debate_outcomes (
	id           INTEGER PRIMARY KEY AUTOINCREMENT,
	thread_id    TEXT NOT NULL UNIQUE,
	topic        TEXT NOT NULL,
	outcome      TEXT NOT NULL, -- synthesized|consensus-agree|consensus-disagree|unresolved
	resolution   TEXT NOT NULL,
	participants TEXT NOT NULL DEFAULT '[]', -- JSON array of agent names
	recorded_by  TEXT NOT NULL,
	created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_debate_topic ON debate_outcomes(topic);
`

const createSpawnSlotsTable = `
CREATE TABLE IF NOT EXISTS spawn_slots (
	id             INTEGER PRIMARY KEY AUTOINCREMENT,
	agent_name     TEXT NOT NULL UNIQUE,
	role           TEXT NOT NULL,
	allocated_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	released_at    DATETIME
);
CREATE INDEX IF NOT EXISTS idx_spawn_active ON spawn_slots(released_at);
`

const createConfigTable = `
CREATE TABLE IF NOT EXISTS config (
	key        TEXT PRIMARY KEY,
	value      TEXT NOT NULL,
	updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
`

// ─── Task Operations ──────────────────────────────────────────────────────────

// UpsertTask inserts or updates a task in the queue.
func (s *Store) UpsertTask(t *types.Task) error {
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		INSERT INTO tasks (issue_number, title, labels, priority, status, agent_name, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(issue_number) DO UPDATE SET
			title      = excluded.title,
			labels     = excluded.labels,
			priority   = excluded.priority,
			updated_at = excluded.updated_at
		WHERE status = 'pending'
	`, t.IssueNumber, t.Title, t.Labels, t.Priority, t.Status, t.AgentName, now, now)
	return err
}

// ClaimTask atomically claims a task for an agent.
// Returns (task, true, nil) if claimed, (nil, false, nil) if already claimed.
// This replaces the CAS loop in claim_task() bash function.
func (s *Store) ClaimTask(issueNumber int, agentName string) (*types.Task, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback()

	// Check current state with SELECT FOR UPDATE semantics (SQLite exclusive via transaction)
	var task types.Task
	err = tx.QueryRow(`
		SELECT id, issue_number, title, labels, priority, status, agent_name
		FROM tasks
		WHERE issue_number = ? AND status = 'pending'
	`, issueNumber).Scan(
		&task.ID, &task.IssueNumber, &task.Title, &task.Labels,
		&task.Priority, &task.Status, &task.AgentName,
	)
	if err == sql.ErrNoRows {
		return nil, false, nil // already claimed or not in queue
	}
	if err != nil {
		return nil, false, err
	}

	now := time.Now().UTC()
	_, err = tx.Exec(`
		UPDATE tasks SET status='claimed', agent_name=?, claimed_at=?, updated_at=?
		WHERE id=? AND status='pending'
	`, agentName, now, now, task.ID)
	if err != nil {
		return nil, false, err
	}

	task.Status = types.TaskStatusClaimed
	task.AgentName = agentName
	task.ClaimedAt = &now

	return &task, true, tx.Commit()
}

// ReleaseTask marks a task as done or failed.
func (s *Store) ReleaseTask(issueNumber int, agentName string, status types.TaskStatus) error {
	now := time.Now().UTC()
	result, err := s.db.Exec(`
		UPDATE tasks SET status=?, completed_at=?, updated_at=?
		WHERE issue_number=? AND agent_name=?
	`, status, now, now, issueNumber, agentName)
	if err != nil {
		return err
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("task %d not found or not owned by %s", issueNumber, agentName)
	}
	return nil
}

// ListPendingTasks returns pending tasks ordered by priority (highest first).
func (s *Store) ListPendingTasks(limit int) ([]*types.Task, error) {
	rows, err := s.db.Query(`
		SELECT id, issue_number, title, labels, priority, status, agent_name, created_at, updated_at
		FROM tasks
		WHERE status = 'pending'
		ORDER BY priority DESC, created_at ASC
		LIMIT ?
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tasks []*types.Task
	for rows.Next() {
		var t types.Task
		if err := rows.Scan(&t.ID, &t.IssueNumber, &t.Title, &t.Labels, &t.Priority,
			&t.Status, &t.AgentName, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return nil, err
		}
		tasks = append(tasks, &t)
	}
	return tasks, rows.Err()
}

// GetStaleAssignments returns tasks claimed longer than the timeout.
// Replaces the stale assignment cleanup in coordinator.sh.
func (s *Store) GetStaleAssignments(timeout time.Duration) ([]*types.Task, error) {
	cutoff := time.Now().UTC().Add(-timeout)
	rows, err := s.db.Query(`
		SELECT id, issue_number, title, labels, priority, status, agent_name, claimed_at
		FROM tasks
		WHERE status = 'claimed' AND claimed_at < ?
	`, cutoff)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tasks []*types.Task
	for rows.Next() {
		var t types.Task
		if err := rows.Scan(&t.ID, &t.IssueNumber, &t.Title, &t.Labels, &t.Priority,
			&t.Status, &t.AgentName, &t.ClaimedAt); err != nil {
			return nil, err
		}
		tasks = append(tasks, &t)
	}
	return tasks, rows.Err()
}

// ReclaimStaleTask resets a stale task back to pending.
func (s *Store) ReclaimStaleTask(id int64) error {
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		UPDATE tasks SET status='pending', agent_name='', claimed_at=NULL, updated_at=?
		WHERE id=?
	`, now, id)
	return err
}

// ─── Agent Operations ─────────────────────────────────────────────────────────

// UpsertAgent registers or updates an agent's heartbeat.
func (s *Store) UpsertAgent(a *types.Agent) error {
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		INSERT INTO agents (name, role, generation, display_name, specialization, registered_at, last_seen_at, active)
		VALUES (?, ?, ?, ?, ?, ?, ?, TRUE)
		ON CONFLICT(name) DO UPDATE SET
			role           = excluded.role,
			last_seen_at   = excluded.last_seen_at,
			display_name   = COALESCE(NULLIF(excluded.display_name,''), agents.display_name),
			specialization = COALESCE(NULLIF(excluded.specialization,''), agents.specialization),
			active         = TRUE
	`, a.Name, a.Role, a.Generation, a.DisplayName, a.Specialization, now, now)
	return err
}

// MarkAgentInactive marks an agent as no longer active.
func (s *Store) MarkAgentInactive(name string) error {
	_, err := s.db.Exec(`UPDATE agents SET active=FALSE WHERE name=?`, name)
	return err
}

// GetActiveAgentCount returns the number of currently active agents.
func (s *Store) GetActiveAgentCount() (int, error) {
	var count int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM agents WHERE active=TRUE`).Scan(&count)
	return count, err
}

// FindSpecializedAgent finds an active agent specializing in the given label.
// Used for specialization-based task routing (issue #1113).
func (s *Store) FindSpecializedAgent(label string) (*types.Agent, error) {
	var a types.Agent
	err := s.db.QueryRow(`
		SELECT name, role, generation, display_name, specialization, last_seen_at
		FROM agents
		WHERE active=TRUE AND specialization LIKE ?
		ORDER BY last_seen_at DESC
		LIMIT 1
	`, "%"+label+"%").Scan(&a.Name, &a.Role, &a.Generation, &a.DisplayName, &a.Specialization, &a.LastSeenAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return &a, err
}

// ─── Vote Operations ──────────────────────────────────────────────────────────

// RecordVote records a vote, replacing any previous vote by the same agent on the topic.
func (s *Store) RecordVote(v *types.Vote) error {
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		INSERT INTO votes (topic, proposal_id, agent_name, status, value, reason, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(topic, agent_name) DO UPDATE SET
			status     = excluded.status,
			value      = excluded.value,
			reason     = excluded.reason,
			created_at = excluded.created_at
	`, v.Topic, v.ProposalID, v.AgentName, v.Status, v.Value, v.Reason, now)
	return err
}

// TallyVotes counts votes for a topic. Returns (approve, reject, abstain, error).
// This replaces tally_votes() in coordinator.sh with atomic SQL.
func (s *Store) TallyVotes(topic string) (approve, reject, abstain int, err error) {
	rows, err := s.db.Query(`
		SELECT status, COUNT(*) FROM votes WHERE topic=? GROUP BY status
	`, topic)
	if err != nil {
		return
	}
	defer rows.Close()

	for rows.Next() {
		var status string
		var count int
		if err = rows.Scan(&status, &count); err != nil {
			return
		}
		switch types.VoteStatus(status) {
		case types.VoteApprove:
			approve = count
		case types.VoteReject:
			reject = count
		case types.VoteAbstain:
			abstain = count
		}
	}
	err = rows.Err()
	return
}

// GetTopVoteValue returns the most common value voted for a topic (e.g. circuitBreakerLimit=12).
func (s *Store) GetTopVoteValue(topic string) (string, error) {
	var value string
	err := s.db.QueryRow(`
		SELECT value FROM votes
		WHERE topic=? AND status='approve' AND value != ''
		GROUP BY value ORDER BY COUNT(*) DESC LIMIT 1
	`, topic).Scan(&value)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return value, err
}

// ─── Proposal Operations ──────────────────────────────────────────────────────

// CreateProposal stores a new governance proposal.
func (s *Store) CreateProposal(p *types.Proposal) error {
	now := time.Now().UTC()
	result, err := s.db.Exec(`
		INSERT INTO proposals (topic, agent_name, content, key, value, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, p.Topic, p.AgentName, p.Content, p.Key, p.Value, now)
	if err != nil {
		return err
	}
	p.ID, err = result.LastInsertId()
	return err
}

// MarkProposalEnacted marks a proposal as enacted.
func (s *Store) MarkProposalEnacted(topic string) error {
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		UPDATE proposals SET enacted=TRUE, enacted_at=? WHERE topic=? AND enacted=FALSE
	`, now, topic)
	return err
}

// GetUnenactedProposals returns proposals that haven't been enacted yet.
func (s *Store) GetUnenactedProposals() ([]*types.Proposal, error) {
	rows, err := s.db.Query(`
		SELECT id, topic, agent_name, content, key, value, created_at
		FROM proposals WHERE enacted=FALSE
		ORDER BY created_at ASC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var proposals []*types.Proposal
	for rows.Next() {
		var p types.Proposal
		if err := rows.Scan(&p.ID, &p.Topic, &p.AgentName, &p.Content,
			&p.Key, &p.Value, &p.CreatedAt); err != nil {
			return nil, err
		}
		proposals = append(proposals, &p)
	}
	return proposals, rows.Err()
}

// ─── Debate Operations ────────────────────────────────────────────────────────

// UpsertDebateOutcome stores a debate resolution, replacing any existing one for the thread.
func (s *Store) UpsertDebateOutcome(d *types.DebateOutcome) error {
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		INSERT INTO debate_outcomes (thread_id, topic, outcome, resolution, participants, recorded_by, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(thread_id) DO UPDATE SET
			outcome      = excluded.outcome,
			resolution   = excluded.resolution,
			participants = excluded.participants,
			recorded_by  = excluded.recorded_by
	`, d.ThreadID, d.Topic, d.Outcome, d.Resolution, d.Participants, d.RecordedBy, now)
	return err
}

// QueryDebateOutcomes returns debate outcomes matching the given topic (or all if empty).
func (s *Store) QueryDebateOutcomes(topic string) ([]*types.DebateOutcome, error) {
	query := `
		SELECT id, thread_id, topic, outcome, resolution, participants, recorded_by, created_at
		FROM debate_outcomes
	`
	var args []interface{}
	if topic != "" {
		query += " WHERE topic LIKE ?"
		args = append(args, "%"+topic+"%")
	}
	query += " ORDER BY created_at DESC LIMIT 50"

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var outcomes []*types.DebateOutcome
	for rows.Next() {
		var d types.DebateOutcome
		if err := rows.Scan(&d.ID, &d.ThreadID, &d.Topic, &d.Outcome, &d.Resolution,
			&d.Participants, &d.RecordedBy, &d.CreatedAt); err != nil {
			return nil, err
		}
		outcomes = append(outcomes, &d)
	}
	return outcomes, rows.Err()
}

// ─── Spawn Slot Operations ────────────────────────────────────────────────────

// AllocateSpawnSlot atomically allocates a spawn slot for an agent.
// Returns (true, nil) if slot allocated, (false, nil) if circuit breaker full.
// This replaces request_spawn_slot() CAS loop in entrypoint.sh.
func (s *Store) AllocateSpawnSlot(agentName, role string, limit int) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	var active int
	if err := tx.QueryRow(`
		SELECT COUNT(*) FROM spawn_slots WHERE released_at IS NULL
	`).Scan(&active); err != nil {
		return false, err
	}

	if active >= limit {
		return false, nil // circuit breaker full
	}

	now := time.Now().UTC()
	if _, err := tx.Exec(`
		INSERT INTO spawn_slots (agent_name, role, allocated_at) VALUES (?, ?, ?)
		ON CONFLICT(agent_name) DO UPDATE SET allocated_at=excluded.allocated_at, released_at=NULL
	`, agentName, role, now); err != nil {
		return false, err
	}

	return true, tx.Commit()
}

// ReleaseSpawnSlot marks a spawn slot as released.
func (s *Store) ReleaseSpawnSlot(agentName string) error {
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		UPDATE spawn_slots SET released_at=? WHERE agent_name=? AND released_at IS NULL
	`, now, agentName)
	return err
}

// GetActiveSpawnCount returns the number of currently active spawn slots.
func (s *Store) GetActiveSpawnCount() (int, error) {
	var count int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM spawn_slots WHERE released_at IS NULL`).Scan(&count)
	return count, err
}

// ─── Config Operations ────────────────────────────────────────────────────────

// SetConfig stores a configuration key-value pair.
func (s *Store) SetConfig(key, value string) error {
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		INSERT INTO config (key, value, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
	`, key, value, now)
	return err
}

// GetConfig retrieves a configuration value by key.
// Returns ("", nil) if the key does not exist.
func (s *Store) GetConfig(key string) (string, error) {
	var value string
	err := s.db.QueryRow(`SELECT value FROM config WHERE key=?`, key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return value, err
}
