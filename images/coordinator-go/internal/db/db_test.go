// Package db tests the SQLite initialization and schema migrations.
// These tests verify that the work-ledger schema applies cleanly and
// that all expected tables, indexes, triggers, and views exist.
package db

import (
	"database/sql"
	"os"
	"testing"
)

// openTestDB opens an in-memory SQLite database for testing.
// Using an in-memory DB avoids filesystem side effects and is instant.
func openTestDB(t *testing.T) *DB {
	t.Helper()
	db, err := Open(":memory:")
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// TestOpen verifies that Open succeeds with an in-memory database.
func TestOpen(t *testing.T) {
	db := openTestDB(t)
	if err := db.Ping(); err != nil {
		t.Fatalf("ping: %v", err)
	}
}

// TestOpenCreatesDir verifies that Open creates the parent directory when needed.
func TestOpenCreatesDir(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/subdir/coordinator.db"
	db, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = db.Close() }()

	if _, err := os.Stat(path); err != nil {
		t.Errorf("db file should exist at %s: %v", path, err)
	}
}

// TestSchemaTablesExist verifies all 9 work-ledger tables are created.
func TestSchemaTablesExist(t *testing.T) {
	db := openTestDB(t)

	want := []string{
		"tasks",
		"agents",
		"agent_activity",
		"proposals",
		"votes",
		"debates",
		"metrics",
		"vision_queue",
		"constitution_log",
	}

	for _, table := range want {
		t.Run(table, func(t *testing.T) {
			var name string
			err := db.QueryRow(
				`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table,
			).Scan(&name)
			if err == sql.ErrNoRows {
				t.Errorf("table %q not found in schema", table)
			} else if err != nil {
				t.Errorf("query table %q: %v", table, err)
			}
		})
	}
}

// TestSchemaViewsExist verifies all 6 compatibility views are created.
func TestSchemaViewsExist(t *testing.T) {
	db := openTestDB(t)

	want := []string{
		"v_task_queue",
		"v_active_assignments",
		"v_debate_stats",
		"v_open_proposals",
		"v_agent_leaderboard",
		"v_civilization_metrics",
	}

	for _, view := range want {
		t.Run(view, func(t *testing.T) {
			var name string
			err := db.QueryRow(
				`SELECT name FROM sqlite_master WHERE type='view' AND name=?`, view,
			).Scan(&name)
			if err == sql.ErrNoRows {
				t.Errorf("view %q not found in schema", view)
			} else if err != nil {
				t.Errorf("query view %q: %v", view, err)
			}
		})
	}
}

// TestSchemaTriggersExist verifies the 4 updated_at triggers are created.
func TestSchemaTriggersExist(t *testing.T) {
	db := openTestDB(t)

	want := []string{
		"trg_tasks_updated_at",
		"trg_agents_updated_at",
		"trg_proposals_updated_at",
		"trg_proposals_vote_count",
	}

	for _, trigger := range want {
		t.Run(trigger, func(t *testing.T) {
			var name string
			err := db.QueryRow(
				`SELECT name FROM sqlite_master WHERE type='trigger' AND name=?`, trigger,
			).Scan(&name)
			if err == sql.ErrNoRows {
				t.Errorf("trigger %q not found in schema", trigger)
			} else if err != nil {
				t.Errorf("query trigger %q: %v", trigger, err)
			}
		})
	}
}

// TestMigrateIdempotent verifies that applying the schema twice does not error.
// All DDL uses IF NOT EXISTS, so double-apply should be safe.
func TestMigrateIdempotent(t *testing.T) {
	db := openTestDB(t)
	// Apply migration a second time — should not return an error.
	if err := db.migrate(); err != nil {
		t.Errorf("second migrate: %v", err)
	}
}

// TestTasksInsert verifies that the tasks table accepts valid inserts.
func TestTasksInsert(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`
		INSERT INTO tasks (issue_number, title, labels, effort, state, priority, source)
		VALUES (42, 'Test task', '["bug"]', 'S', 'queued', 5, 'github')
	`)
	if err != nil {
		t.Fatalf("insert task: %v", err)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM tasks WHERE issue_number=42`).Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 task, got %d", count)
	}
}

// TestTasksIssueNumberUnique verifies the UNIQUE constraint on issue_number.
func TestTasksIssueNumberUnique(t *testing.T) {
	db := openTestDB(t)

	insert := func() error {
		_, err := db.Exec(`
			INSERT INTO tasks (issue_number, title, state, priority, source)
			VALUES (99, 'Duplicate issue', 'queued', 5, 'github')
		`)
		return err
	}

	if err := insert(); err != nil {
		t.Fatalf("first insert: %v", err)
	}
	if err := insert(); err == nil {
		t.Error("expected UNIQUE constraint error on second insert, got nil")
	}
}

// TestDebatesView verifies v_debate_stats returns correct totals.
func TestDebatesView(t *testing.T) {
	db := openTestDB(t)

	// Insert two debate rows.
	stmts := []string{
		`INSERT INTO debates (thread_id, agent_name, stance, content, confidence, is_resolved)
		 VALUES ('thread-1', 'worker-001', 'disagree', 'I disagree because X', 8, 0)`,
		`INSERT INTO debates (thread_id, agent_name, stance, content, confidence, is_resolved)
		 VALUES ('thread-1', 'worker-002', 'synthesize', 'Synthesis: compromise Y', 9, 1)`,
	}
	for _, stmt := range stmts {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("insert debate: %v", err)
		}
	}

	var total, threads, disagree, synthesize, unresolved int
	err := db.QueryRow(`
		SELECT total_responses, total_threads, disagree_count, synthesize_count, unresolved_count
		FROM v_debate_stats
	`).Scan(&total, &threads, &disagree, &synthesize, &unresolved)
	if err != nil {
		t.Fatalf("query v_debate_stats: %v", err)
	}

	if total != 2 {
		t.Errorf("total_responses: got %d, want 2", total)
	}
	if threads != 1 {
		t.Errorf("total_threads: got %d, want 1", threads)
	}
	if disagree != 1 {
		t.Errorf("disagree_count: got %d, want 1", disagree)
	}
	if synthesize != 1 {
		t.Errorf("synthesize_count: got %d, want 1", synthesize)
	}
	if unresolved != 1 { // only the disagree row has is_resolved=0
		t.Errorf("unresolved_count: got %d, want 1", unresolved)
	}
}

// TestVoteCountTrigger verifies trg_proposals_vote_count auto-updates tallies.
func TestVoteCountTrigger(t *testing.T) {
	db := openTestDB(t)

	// Create a proposal.
	var proposalID int64
	err := db.QueryRow(`
		INSERT INTO proposals (topic, key, value, proposed_by, threshold)
		VALUES ('circuit-breaker', 'circuitBreakerLimit', '12', 'planner-001', 3)
		RETURNING id
	`).Scan(&proposalID)
	if err != nil {
		t.Fatalf("insert proposal: %v", err)
	}

	// Cast two approve votes.
	votes := []struct{ voter, stance string }{
		{"worker-001", "approve"},
		{"worker-002", "approve"},
	}
	for _, v := range votes {
		_, err := db.Exec(`
			INSERT INTO votes (proposal_id, voter, stance)
			VALUES (?, ?, ?)
		`, proposalID, v.voter, v.stance)
		if err != nil {
			t.Fatalf("insert vote (%s): %v", v.voter, err)
		}
	}

	// Trigger should have updated vote_approve to 2.
	var approve, reject, abstain int
	err = db.QueryRow(`
		SELECT vote_approve, vote_reject, vote_abstain FROM proposals WHERE id=?
	`, proposalID).Scan(&approve, &reject, &abstain)
	if err != nil {
		t.Fatalf("query proposal: %v", err)
	}

	if approve != 2 {
		t.Errorf("vote_approve: got %d, want 2", approve)
	}
	if reject != 0 {
		t.Errorf("vote_reject: got %d, want 0", reject)
	}
	if abstain != 0 {
		t.Errorf("vote_abstain: got %d, want 0", abstain)
	}
}
