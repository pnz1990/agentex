// Package state provides persistent state management for the agentex coordinator.
// It replaces the ConfigMap string approach with SQLite for type safety and reliability.
package state

import (
	"database/sql"
	"fmt"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// DB is the persistent state store for the coordinator.
type DB struct {
	db  *sql.DB
	mu  sync.RWMutex
	path string
}

// Task represents a work item in the task queue.
type Task struct {
	ID          int64
	IssueNumber int
	Title       string
	Labels      string // comma-separated
	Priority    int    // higher = more urgent
	State       string // queued, assigned, done, stale
	AssignedTo  string // agent name, or ""
	ClaimedAt   *time.Time
	CompletedAt *time.Time
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// Assignment tracks which agent is working on which issue.
type Assignment struct {
	AgentName    string
	IssueNumber  int
	ClaimedAt    time.Time
	LastHeartbeat time.Time
	State        string // active, stale
}

// Vote represents a single agent's vote on a governance proposal.
type Vote struct {
	ID          int64
	Topic       string
	AgentName   string
	Stance      string // approve, reject, abstain
	Value       string // proposed value (e.g., "12" for circuitBreakerLimit)
	Reason      string
	CreatedAt   time.Time
}

// Decision records an enacted governance decision.
type Decision struct {
	ID          int64
	Topic       string
	EnactedAt   time.Time
	Value       string
	ApproveVotes int
	Reason      string
}

// DebateOutcome records a resolved debate for anti-amnesia.
type DebateOutcome struct {
	ThreadID    string
	Topic       string
	Outcome     string // synthesized, consensus-agree, consensus-disagree, unresolved
	Resolution  string
	Participants string // JSON array of agent names
	RecordedBy  string
	CreatedAt   time.Time
}

// AgentStats tracks per-agent metrics.
type AgentStats struct {
	AgentName     string
	Role          string
	Generation    int
	VisionScore   float64
	TasksDone     int
	PRsOpened     int
	DebateCount   int
	LastSeen      time.Time
	Specialization string
}

// New opens (or creates) the SQLite database at the given path.
func New(path string) (*DB, error) {
	// Enable WAL mode for better concurrent read/write performance
	db, err := sql.Open("sqlite3", path+"?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=on")
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}

	// Set reasonable connection pool limits
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(30 * time.Minute)

	s := &DB{db: db, path: path}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

// Close closes the database connection.
func (s *DB) Close() error {
	return s.db.Close()
}

// migrate applies all schema migrations.
func (s *DB) migrate() error {
	migrations := []string{
		`CREATE TABLE IF NOT EXISTS schema_version (
			version INTEGER PRIMARY KEY,
			applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE IF NOT EXISTS tasks (
			id            INTEGER PRIMARY KEY AUTOINCREMENT,
			issue_number  INTEGER NOT NULL UNIQUE,
			title         TEXT NOT NULL,
			labels        TEXT NOT NULL DEFAULT '',
			priority      INTEGER NOT NULL DEFAULT 0,
			state         TEXT NOT NULL DEFAULT 'queued',
			assigned_to   TEXT NOT NULL DEFAULT '',
			claimed_at    TIMESTAMP,
			completed_at  TIMESTAMP,
			created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state)`,
		`CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to ON tasks(assigned_to)`,
		`CREATE TABLE IF NOT EXISTS assignments (
			agent_name     TEXT NOT NULL,
			issue_number   INTEGER NOT NULL,
			claimed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			last_heartbeat TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			state          TEXT NOT NULL DEFAULT 'active',
			PRIMARY KEY (agent_name, issue_number)
		)`,
		`CREATE TABLE IF NOT EXISTS votes (
			id          INTEGER PRIMARY KEY AUTOINCREMENT,
			topic       TEXT NOT NULL,
			agent_name  TEXT NOT NULL,
			stance      TEXT NOT NULL,
			value       TEXT NOT NULL DEFAULT '',
			reason      TEXT NOT NULL DEFAULT '',
			created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			UNIQUE(topic, agent_name)
		)`,
		`CREATE TABLE IF NOT EXISTS decisions (
			id            INTEGER PRIMARY KEY AUTOINCREMENT,
			topic         TEXT NOT NULL,
			enacted_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			value         TEXT NOT NULL DEFAULT '',
			approve_votes INTEGER NOT NULL DEFAULT 0,
			reason        TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS debate_outcomes (
			thread_id    TEXT PRIMARY KEY,
			topic        TEXT NOT NULL,
			outcome      TEXT NOT NULL,
			resolution   TEXT NOT NULL DEFAULT '',
			participants TEXT NOT NULL DEFAULT '[]',
			recorded_by  TEXT NOT NULL DEFAULT '',
			created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE INDEX IF NOT EXISTS idx_debate_outcomes_topic ON debate_outcomes(topic)`,
		`CREATE TABLE IF NOT EXISTS agent_stats (
			agent_name      TEXT PRIMARY KEY,
			role            TEXT NOT NULL DEFAULT '',
			generation      INTEGER NOT NULL DEFAULT 0,
			vision_score    REAL NOT NULL DEFAULT 0,
			tasks_done      INTEGER NOT NULL DEFAULT 0,
			prs_opened      INTEGER NOT NULL DEFAULT 0,
			debate_count    INTEGER NOT NULL DEFAULT 0,
			last_seen       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			specialization  TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS spawn_slots (
			id          INTEGER PRIMARY KEY CHECK (id = 1),
			available   INTEGER NOT NULL DEFAULT 10,
			updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		`INSERT OR IGNORE INTO spawn_slots (id, available) VALUES (1, 10)`,
		`CREATE TABLE IF NOT EXISTS kvstore (
			key         TEXT PRIMARY KEY,
			value       TEXT NOT NULL DEFAULT '',
			updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for _, m := range migrations {
		if _, err := tx.Exec(m); err != nil {
			return fmt.Errorf("migration %q: %w", m[:min(50, len(m))], err)
		}
	}
	return tx.Commit()
}

// ─── Task Queue ──────────────────────────────────────────────────────────────

// UpsertTask inserts or updates a task by issue number.
func (s *DB) UpsertTask(t *Task) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		INSERT INTO tasks (issue_number, title, labels, priority, state, updated_at)
		VALUES (?, ?, ?, ?, 'queued', CURRENT_TIMESTAMP)
		ON CONFLICT(issue_number) DO UPDATE SET
			title    = excluded.title,
			labels   = excluded.labels,
			priority = excluded.priority,
			updated_at = CURRENT_TIMESTAMP
		WHERE state IN ('queued', 'stale')
	`, t.IssueNumber, t.Title, t.Labels, t.Priority)
	return err
}

// ClaimTask atomically claims a task for an agent. Returns false if already claimed.
func (s *DB) ClaimTask(agentName string, issueNumber int) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	// Check if task exists and is available
	var state string
	err = tx.QueryRow(
		`SELECT state FROM tasks WHERE issue_number = ? FOR UPDATE`, issueNumber,
	).Scan(&state)
	if err == sql.ErrNoRows {
		return false, fmt.Errorf("task %d not found", issueNumber)
	}
	if err != nil {
		return false, err
	}
	if state != "queued" && state != "stale" {
		return false, nil // already claimed or done
	}

	now := time.Now().UTC()
	// Mark task as assigned
	_, err = tx.Exec(`
		UPDATE tasks SET state = 'assigned', assigned_to = ?, claimed_at = ?, updated_at = ?
		WHERE issue_number = ? AND state IN ('queued', 'stale')
	`, agentName, now, now, issueNumber)
	if err != nil {
		return false, err
	}

	// Record assignment
	_, err = tx.Exec(`
		INSERT INTO assignments (agent_name, issue_number, claimed_at, last_heartbeat, state)
		VALUES (?, ?, ?, ?, 'active')
		ON CONFLICT(agent_name, issue_number) DO UPDATE SET
			claimed_at = excluded.claimed_at,
			last_heartbeat = excluded.last_heartbeat,
			state = 'active'
	`, agentName, issueNumber, now, now)
	if err != nil {
		return false, err
	}

	return true, tx.Commit()
}

// ReleaseTask marks a task as done when an agent completes it.
func (s *DB) ReleaseTask(agentName string, issueNumber int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().UTC()
	_, err := s.db.Exec(`
		UPDATE tasks SET state = 'done', completed_at = ?, updated_at = ?
		WHERE issue_number = ? AND assigned_to = ?
	`, now, now, issueNumber, agentName)
	return err
}

// GetQueuedTasks returns all tasks in queued or stale state.
func (s *DB) GetQueuedTasks(limit int) ([]Task, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows, err := s.db.Query(`
		SELECT id, issue_number, title, labels, priority, state, assigned_to,
		       claimed_at, completed_at, created_at, updated_at
		FROM tasks WHERE state IN ('queued', 'stale')
		ORDER BY priority DESC, created_at ASC
		LIMIT ?
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanTasks(rows)
}

// GetActiveAssignments returns all currently active assignments.
func (s *DB) GetActiveAssignments() ([]Assignment, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows, err := s.db.Query(`
		SELECT agent_name, issue_number, claimed_at, last_heartbeat, state
		FROM assignments WHERE state = 'active'
		ORDER BY claimed_at ASC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanAssignments(rows)
}

// UpdateAssignmentHeartbeat updates the last_heartbeat for an assignment.
func (s *DB) UpdateAssignmentHeartbeat(agentName string, issueNumber int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		UPDATE assignments SET last_heartbeat = CURRENT_TIMESTAMP
		WHERE agent_name = ? AND issue_number = ?
	`, agentName, issueNumber)
	return err
}

// CleanupStaleAssignments releases assignments that haven't heartbeated recently.
// Stale timeout is configurable (default: 5 minutes).
func (s *DB) CleanupStaleAssignments(staleAfter time.Duration) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	cutoff := time.Now().UTC().Add(-staleAfter)

	// Find stale assignments
	rows, err := tx.Query(`
		SELECT agent_name, issue_number FROM assignments
		WHERE state = 'active' AND last_heartbeat < ?
	`, cutoff)
	if err != nil {
		return 0, err
	}
	var stale []struct{ agent string; issue int }
	for rows.Next() {
		var a struct{ agent string; issue int }
		if err := rows.Scan(&a.agent, &a.issue); err != nil {
			rows.Close()
			return 0, err
		}
		stale = append(stale, a)
	}
	rows.Close()

	count := 0
	for _, a := range stale {
		// Return task to queue
		_, err = tx.Exec(`
			UPDATE tasks SET state = 'stale', assigned_to = '', claimed_at = NULL, updated_at = CURRENT_TIMESTAMP
			WHERE issue_number = ? AND assigned_to = ?
		`, a.issue, a.agent)
		if err != nil {
			return count, err
		}
		// Mark assignment stale
		_, err = tx.Exec(`
			UPDATE assignments SET state = 'stale'
			WHERE agent_name = ? AND issue_number = ?
		`, a.agent, a.issue)
		if err != nil {
			return count, err
		}
		count++
	}
	return count, tx.Commit()
}

// ─── Governance / Voting ─────────────────────────────────────────────────────

// RecordVote records or updates an agent's vote on a topic.
func (s *DB) RecordVote(v *Vote) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		INSERT INTO votes (topic, agent_name, stance, value, reason, created_at)
		VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(topic, agent_name) DO UPDATE SET
			stance = excluded.stance,
			value  = excluded.value,
			reason = excluded.reason,
			created_at = CURRENT_TIMESTAMP
	`, v.Topic, v.AgentName, v.Stance, v.Value, v.Reason)
	return err
}

// GetVotesByTopic returns all votes for a given topic.
func (s *DB) GetVotesByTopic(topic string) ([]Vote, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows, err := s.db.Query(`
		SELECT id, topic, agent_name, stance, value, reason, created_at
		FROM votes WHERE topic = ?
		ORDER BY created_at ASC
	`, topic)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanVotes(rows)
}

// CountApproveVotes returns the number of approve votes for a topic.
func (s *DB) CountApproveVotes(topic string) (int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var count int
	err := s.db.QueryRow(
		`SELECT COUNT(*) FROM votes WHERE topic = ? AND stance = 'approve'`, topic,
	).Scan(&count)
	return count, err
}

// RecordDecision persists an enacted governance decision.
func (s *DB) RecordDecision(d *Decision) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		INSERT INTO decisions (topic, enacted_at, value, approve_votes, reason)
		VALUES (?, CURRENT_TIMESTAMP, ?, ?, ?)
	`, d.Topic, d.Value, d.ApproveVotes, d.Reason)
	return err
}

// GetDecisions returns recent enacted decisions.
func (s *DB) GetDecisions(limit int) ([]Decision, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows, err := s.db.Query(`
		SELECT id, topic, enacted_at, value, approve_votes, reason
		FROM decisions ORDER BY enacted_at DESC LIMIT ?
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanDecisions(rows)
}

// HasDecision returns true if a topic has already been enacted.
func (s *DB) HasDecision(topic string) (bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var count int
	err := s.db.QueryRow(
		`SELECT COUNT(*) FROM decisions WHERE topic = ?`, topic,
	).Scan(&count)
	return count > 0, err
}

// ─── Debate Outcomes ─────────────────────────────────────────────────────────

// RecordDebateOutcome persists a resolved debate.
func (s *DB) RecordDebateOutcome(d *DebateOutcome) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		INSERT INTO debate_outcomes (thread_id, topic, outcome, resolution, participants, recorded_by, created_at)
		VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(thread_id) DO UPDATE SET
			outcome     = excluded.outcome,
			resolution  = excluded.resolution,
			participants = excluded.participants
	`, d.ThreadID, d.Topic, d.Outcome, d.Resolution, d.Participants, d.RecordedBy)
	return err
}

// QueryDebatesByTopic returns debate outcomes matching a topic keyword.
func (s *DB) QueryDebatesByTopic(topic string) ([]DebateOutcome, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rows, err := s.db.Query(`
		SELECT thread_id, topic, outcome, resolution, participants, recorded_by, created_at
		FROM debate_outcomes WHERE topic LIKE ?
		ORDER BY created_at DESC LIMIT 50
	`, "%"+topic+"%")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanDebateOutcomes(rows)
}

// ─── Spawn Control ───────────────────────────────────────────────────────────

// GetAvailableSpawnSlots returns the current number of available spawn slots.
func (s *DB) GetAvailableSpawnSlots() (int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var available int
	err := s.db.QueryRow(`SELECT available FROM spawn_slots WHERE id = 1`).Scan(&available)
	return available, err
}

// RequestSpawnSlot atomically decrements available spawn slots.
// Returns true if a slot was granted, false if none available.
func (s *DB) RequestSpawnSlot() (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	var available int
	if err := tx.QueryRow(`SELECT available FROM spawn_slots WHERE id = 1`).Scan(&available); err != nil {
		return false, err
	}
	if available <= 0 {
		return false, nil
	}

	_, err = tx.Exec(`
		UPDATE spawn_slots SET available = available - 1, updated_at = CURRENT_TIMESTAMP
		WHERE id = 1
	`)
	if err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// ReleaseSpawnSlot increments available spawn slots (called when agent completes).
func (s *DB) ReleaseSpawnSlot() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		UPDATE spawn_slots
		SET available = MIN(available + 1, (SELECT CAST(value AS INTEGER) FROM kvstore WHERE key = 'circuitBreakerLimit' LIMIT 1)),
		    updated_at = CURRENT_TIMESTAMP
		WHERE id = 1
	`)
	return err
}

// SetCircuitBreakerLimit updates the max spawn slots.
func (s *DB) SetCircuitBreakerLimit(limit int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.Exec(`
		INSERT INTO kvstore (key, value) VALUES ('circuitBreakerLimit', ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP
	`, fmt.Sprintf("%d", limit))
	if err != nil {
		return err
	}
	_, err = tx.Exec(`
		UPDATE spawn_slots SET available = ?, updated_at = CURRENT_TIMESTAMP WHERE id = 1
	`, limit)
	if err != nil {
		return err
	}
	return tx.Commit()
}

// ─── KV Store ────────────────────────────────────────────────────────────────

// Set stores a key-value pair in the kvstore.
func (s *DB) Set(key, value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		INSERT INTO kvstore (key, value) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP
	`, key, value)
	return err
}

// Get retrieves a value from the kvstore. Returns "", nil if not found.
func (s *DB) Get(key string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var value string
	err := s.db.QueryRow(`SELECT value FROM kvstore WHERE key = ?`, key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return value, err
}

// ─── Agent Stats ─────────────────────────────────────────────────────────────

// UpsertAgentStats inserts or updates agent statistics.
func (s *DB) UpsertAgentStats(stats *AgentStats) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`
		INSERT INTO agent_stats (agent_name, role, generation, vision_score, tasks_done, prs_opened, debate_count, last_seen, specialization)
		VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?)
		ON CONFLICT(agent_name) DO UPDATE SET
			role           = excluded.role,
			generation     = excluded.generation,
			vision_score   = CASE WHEN excluded.vision_score > 0 THEN excluded.vision_score ELSE vision_score END,
			tasks_done     = tasks_done + excluded.tasks_done,
			prs_opened     = prs_opened + excluded.prs_opened,
			debate_count   = debate_count + excluded.debate_count,
			last_seen      = CURRENT_TIMESTAMP,
			specialization = CASE WHEN excluded.specialization != '' THEN excluded.specialization ELSE specialization END
	`, stats.AgentName, stats.Role, stats.Generation, stats.VisionScore,
		stats.TasksDone, stats.PRsOpened, stats.DebateCount, stats.Specialization)
	return err
}

// GetDebateStats returns aggregated debate statistics across all agents.
func (s *DB) GetDebateStats() (map[string]int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	result := map[string]int{}
	rows, err := s.db.Query(`
		SELECT stance, COUNT(*) as cnt FROM votes GROUP BY stance
	`)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var stance string
		var cnt int
		if err := rows.Scan(&stance, &cnt); err != nil {
			return result, err
		}
		result[stance] = cnt
	}

	// Add total debate outcome counts
	var synCount int
	s.db.QueryRow(`SELECT COUNT(*) FROM debate_outcomes WHERE outcome = 'synthesized'`).Scan(&synCount)
	result["synthesized"] = synCount

	return result, nil
}

// ─── Scan helpers ────────────────────────────────────────────────────────────

func scanTasks(rows *sql.Rows) ([]Task, error) {
	var tasks []Task
	for rows.Next() {
		var t Task
		err := rows.Scan(
			&t.ID, &t.IssueNumber, &t.Title, &t.Labels, &t.Priority,
			&t.State, &t.AssignedTo, &t.ClaimedAt, &t.CompletedAt,
			&t.CreatedAt, &t.UpdatedAt,
		)
		if err != nil {
			return nil, err
		}
		tasks = append(tasks, t)
	}
	return tasks, rows.Err()
}

func scanAssignments(rows *sql.Rows) ([]Assignment, error) {
	var assignments []Assignment
	for rows.Next() {
		var a Assignment
		if err := rows.Scan(&a.AgentName, &a.IssueNumber, &a.ClaimedAt, &a.LastHeartbeat, &a.State); err != nil {
			return nil, err
		}
		assignments = append(assignments, a)
	}
	return assignments, rows.Err()
}

func scanVotes(rows *sql.Rows) ([]Vote, error) {
	var votes []Vote
	for rows.Next() {
		var v Vote
		if err := rows.Scan(&v.ID, &v.Topic, &v.AgentName, &v.Stance, &v.Value, &v.Reason, &v.CreatedAt); err != nil {
			return nil, err
		}
		votes = append(votes, v)
	}
	return votes, rows.Err()
}

func scanDecisions(rows *sql.Rows) ([]Decision, error) {
	var decisions []Decision
	for rows.Next() {
		var d Decision
		if err := rows.Scan(&d.ID, &d.Topic, &d.EnactedAt, &d.Value, &d.ApproveVotes, &d.Reason); err != nil {
			return nil, err
		}
		decisions = append(decisions, d)
	}
	return decisions, rows.Err()
}

func scanDebateOutcomes(rows *sql.Rows) ([]DebateOutcome, error) {
	var outcomes []DebateOutcome
	for rows.Next() {
		var d DebateOutcome
		if err := rows.Scan(&d.ThreadID, &d.Topic, &d.Outcome, &d.Resolution, &d.Participants, &d.RecordedBy, &d.CreatedAt); err != nil {
			return nil, err
		}
		outcomes = append(outcomes, d)
	}
	return outcomes, rows.Err()
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
