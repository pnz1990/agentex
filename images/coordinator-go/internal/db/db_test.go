package db_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/pnz1990/agentex/coordinator/internal/db"
)

// TestOpen verifies that Open creates a database file and applies the schema.
func TestOpen(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.db")

	d, err := db.Open(path)
	if err != nil {
		t.Fatalf("Open(%q) error: %v", path, err)
	}
	defer d.Close()

	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Errorf("database file was not created at %s", path)
	}
}

// TestOpen_AllTablesExist verifies all 9 work-ledger tables are present.
func TestOpen_AllTablesExist(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open error: %v", err)
	}
	defer d.Close()

	tables := []string{
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

	for _, tbl := range tables {
		var name string
		err := d.QueryRow(
			"SELECT name FROM sqlite_master WHERE type='table' AND name=?", tbl,
		).Scan(&name)
		if err != nil {
			t.Errorf("table %q not found: %v", tbl, err)
		}
	}
}

// TestOpen_Idempotent verifies that calling Open twice on the same file does
// not return an error (schema migrations use CREATE TABLE IF NOT EXISTS).
func TestOpen_Idempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.db")

	d1, err := db.Open(path)
	if err != nil {
		t.Fatalf("first Open error: %v", err)
	}
	d1.Close()

	d2, err := db.Open(path)
	if err != nil {
		t.Fatalf("second Open (idempotent) error: %v", err)
	}
	d2.Close()
}

// TestOpen_NestedDir verifies that Open creates parent directories as needed.
func TestOpen_NestedDir(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "deep", "test.db")

	d, err := db.Open(path)
	if err != nil {
		t.Fatalf("Open(%q) with nested dirs error: %v", path, err)
	}
	defer d.Close()

	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Errorf("database file not found at %s", path)
	}
}

// TestPing verifies the Ping helper returns nil for a valid connection.
func TestPing(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open error: %v", err)
	}
	defer d.Close()

	if err := d.Ping(); err != nil {
		t.Errorf("Ping() returned error: %v", err)
	}
}

// TestAllViewsExist verifies all 6 compatibility views are present.
func TestAllViewsExist(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open error: %v", err)
	}
	defer d.Close()

	views := []string{
		"v_task_queue",
		"v_active_assignments",
		"v_debate_stats",
		"v_open_proposals",
		"v_agent_leaderboard",
		"v_civilization_metrics",
	}
	for _, v := range views {
		var name string
		err := d.QueryRow(
			"SELECT name FROM sqlite_master WHERE type='view' AND name=?", v,
		).Scan(&name)
		if err != nil {
			t.Errorf("view %q not found: %v", v, err)
		}
	}
}

// TestInsertTask verifies basic task insertion and retrieval.
func TestInsertTask(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open error: %v", err)
	}
	defer d.Close()

	_, err = d.Exec(`
		INSERT INTO tasks (issue_number, title, state, source, priority)
		VALUES (1234, 'test task', 'queued', 'github', 5)
	`)
	if err != nil {
		t.Fatalf("insert task: %v", err)
	}

	var issue int
	var state string
	err = d.QueryRow("SELECT issue_number, state FROM tasks WHERE issue_number = 1234").Scan(&issue, &state)
	if err != nil {
		t.Fatalf("select task: %v", err)
	}
	if issue != 1234 || state != "queued" {
		t.Errorf("got issue=%d state=%q, want 1234/queued", issue, state)
	}
}

// TestVoteCountTrigger verifies that inserting votes updates proposal counters.
func TestVoteCountTrigger(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open error: %v", err)
	}
	defer d.Close()

	// Create a proposal
	res, err := d.Exec(`
		INSERT INTO proposals (topic, key, value, proposed_by)
		VALUES ('circuitBreakerLimit', 'circuitBreakerLimit', '10', 'test-agent')
	`)
	if err != nil {
		t.Fatalf("insert proposal: %v", err)
	}
	pid, _ := res.LastInsertId()

	// Cast two approve votes
	for _, voter := range []string{"agent-a", "agent-b"} {
		if _, err := d.Exec(`
			INSERT INTO votes (proposal_id, voter, stance) VALUES (?, ?, 'approve')
		`, pid, voter); err != nil {
			t.Fatalf("insert vote for %s: %v", voter, err)
		}
	}

	// Trigger should have updated vote_approve to 2
	var approved int
	if err := d.QueryRow("SELECT vote_approve FROM proposals WHERE id = ?", pid).Scan(&approved); err != nil {
		t.Fatalf("select proposal: %v", err)
	}
	if approved != 2 {
		t.Errorf("vote_approve = %d, want 2 (trigger may not have fired)", approved)
	}
}
