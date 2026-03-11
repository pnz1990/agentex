package db_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/pnz1990/agentex/coordinator/internal/db"
)

func TestOpen(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.db")

	database, err := db.Open(path)
	if err != nil {
		t.Fatalf("db.Open(%q) failed: %v", path, err)
	}
	defer database.Close()

	if err := database.Ping(); err != nil {
		t.Fatalf("Ping() failed after Open: %v", err)
	}
}

func TestSchemaTables(t *testing.T) {
	dir := t.TempDir()
	database, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("db.Open failed: %v", err)
	}
	defer database.Close()

	// All 9 tables that must exist after schema application.
	want := []string{
		"tasks",
		"agents",
		"thoughts",
		"debate_outcomes",
		"governance_proposals",
		"governance_votes",
		"spawn_slots",
		"planning_states",
	}

	for _, table := range want {
		t.Run("table/"+table, func(t *testing.T) {
			var name string
			err := database.QueryRow(
				"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table,
			).Scan(&name)
			if err != nil {
				t.Fatalf("table %q not found in schema: %v", table, err)
			}
			if name != table {
				t.Fatalf("expected table %q, got %q", table, name)
			}
		})
	}
}

func TestSchemaViews(t *testing.T) {
	dir := t.TempDir()
	database, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("db.Open failed: %v", err)
	}
	defer database.Close()

	want := []string{
		"active_agents",
		"pending_tasks",
		"active_assignments",
		"open_proposals",
		"debate_backlog",
		"recent_insights",
	}

	for _, view := range want {
		t.Run("view/"+view, func(t *testing.T) {
			var name string
			err := database.QueryRow(
				"SELECT name FROM sqlite_master WHERE type='view' AND name=?", view,
			).Scan(&name)
			if err != nil {
				t.Fatalf("view %q not found in schema: %v", view, err)
			}
		})
	}
}

func TestSchemaIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.db")

	// Open twice — schema must be idempotent (IF NOT EXISTS guards).
	db1, err := db.Open(path)
	if err != nil {
		t.Fatalf("first Open failed: %v", err)
	}
	db1.Close()

	db2, err := db.Open(path)
	if err != nil {
		t.Fatalf("second Open failed (schema not idempotent): %v", err)
	}
	defer db2.Close()
}

func TestOpenMissingDirectory(t *testing.T) {
	// Opening a db in a non-existent directory should fail.
	_, err := db.Open("/nonexistent/path/test.db")
	if err == nil {
		t.Fatal("expected error opening db in non-existent directory, got nil")
	}
}

func TestInsertTask(t *testing.T) {
	dir := t.TempDir()
	database, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("db.Open failed: %v", err)
	}
	defer database.Close()

	_, err = database.Exec(`
		INSERT INTO tasks (issue_number, title, labels)
		VALUES (1234, 'test task', 'bug,enhancement')
	`)
	if err != nil {
		t.Fatalf("INSERT into tasks failed: %v", err)
	}

	var count int
	database.QueryRow("SELECT COUNT(*) FROM tasks WHERE issue_number=1234").Scan(&count)
	if count != 1 {
		t.Fatalf("expected 1 task, got %d", count)
	}
}

func TestMain(m *testing.M) {
	os.Exit(m.Run())
}
