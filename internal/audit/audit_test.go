package audit

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLogWritesToLocalFile(t *testing.T) {
	tmpDir := t.TempDir()
	localPath := filepath.Join(tmpDir, "audit.jsonl")

	l := New(Config{
		AgentName:  "test-agent",
		Role:       "worker",
		Bucket:     "", // no S3 in tests
		FlushEvery: time.Hour,
		LocalPath:  localPath,
	}, nil)

	l.Log(ActionDispatch, "success", "test details", 42, 0)
	l.Log(ActionPRCreated, "success", "PR #100", 42, 100)

	data, err := os.ReadFile(localPath)
	if err != nil {
		t.Fatalf("reading local buffer: %v", err)
	}

	lines := splitLines(data)
	if len(lines) != 2 {
		t.Fatalf("expected 2 lines, got %d", len(lines))
	}

	var entry1 Entry
	if err := json.Unmarshal(lines[0], &entry1); err != nil {
		t.Fatalf("unmarshaling entry 1: %v", err)
	}
	if entry1.Action != ActionDispatch {
		t.Errorf("entry1.Action = %q, want %q", entry1.Action, ActionDispatch)
	}
	if entry1.IssueNumber != 42 {
		t.Errorf("entry1.IssueNumber = %d, want 42", entry1.IssueNumber)
	}
	if entry1.AgentName != "test-agent" {
		t.Errorf("entry1.AgentName = %q, want %q", entry1.AgentName, "test-agent")
	}
	if entry1.Role != "worker" {
		t.Errorf("entry1.Role = %q, want %q", entry1.Role, "worker")
	}

	var entry2 Entry
	if err := json.Unmarshal(lines[1], &entry2); err != nil {
		t.Fatalf("unmarshaling entry 2: %v", err)
	}
	if entry2.Action != ActionPRCreated {
		t.Errorf("entry2.Action = %q, want %q", entry2.Action, ActionPRCreated)
	}
	if entry2.PRNumber != 100 {
		t.Errorf("entry2.PRNumber = %d, want 100", entry2.PRNumber)
	}
}

func TestLogEntryPreservesTimestamp(t *testing.T) {
	tmpDir := t.TempDir()
	localPath := filepath.Join(tmpDir, "audit.jsonl")

	l := New(Config{
		AgentName:  "agent",
		Role:       "planner",
		LocalPath:  localPath,
		FlushEvery: time.Hour,
	}, nil)

	ts := time.Date(2026, 1, 15, 12, 0, 0, 0, time.UTC)
	l.LogEntry(Entry{
		Timestamp: ts,
		Action:    ActionExit,
		Outcome:   "success",
	})

	data, _ := os.ReadFile(localPath)
	lines := splitLines(data)
	if len(lines) != 1 {
		t.Fatalf("expected 1 line, got %d", len(lines))
	}

	var entry Entry
	if err := json.Unmarshal(lines[0], &entry); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !entry.Timestamp.Equal(ts) {
		t.Errorf("timestamp = %v, want %v", entry.Timestamp, ts)
	}
}

func TestLogEntryFillsDefaults(t *testing.T) {
	tmpDir := t.TempDir()
	localPath := filepath.Join(tmpDir, "audit.jsonl")

	l := New(Config{
		AgentName:  "coord-agent",
		Role:       "coordinator",
		LocalPath:  localPath,
		FlushEvery: time.Hour,
	}, nil)

	// Entry with empty AgentName and Role — should be filled from logger config
	l.LogEntry(Entry{
		Action:  ActionHeartbeat,
		Outcome: "success",
	})

	data, _ := os.ReadFile(localPath)
	lines := splitLines(data)
	var entry Entry
	json.Unmarshal(lines[0], &entry)

	if entry.AgentName != "coord-agent" {
		t.Errorf("AgentName not defaulted, got %q", entry.AgentName)
	}
	if entry.Role != "coordinator" {
		t.Errorf("Role not defaulted, got %q", entry.Role)
	}
	if entry.Timestamp.IsZero() {
		t.Error("Timestamp should be set when empty")
	}
}

func TestLoggerStartStop(t *testing.T) {
	tmpDir := t.TempDir()
	localPath := filepath.Join(tmpDir, "audit.jsonl")

	l := New(Config{
		AgentName:  "agent",
		Role:       "worker",
		Bucket:     "", // no S3 flush
		LocalPath:  localPath,
		FlushEvery: 10 * time.Millisecond,
	}, nil)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		l.Start(ctx)
		close(done)
	}()

	l.Log(ActionTaskStart, "success", "starting task", 55, 0)
	time.Sleep(50 * time.Millisecond) // let flush cycle run (no-op without S3)

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("logger did not stop within 2 seconds")
	}

	// Entry should still be in local buffer (no S3 to flush to)
	data, _ := os.ReadFile(localPath)
	if len(data) == 0 {
		t.Error("local buffer should not be empty after logging")
	}
}

func TestQueryFiltersMatches(t *testing.T) {
	entry := Entry{
		AgentName:   "agent-1",
		IssueNumber: 42,
		Action:      ActionDispatch,
	}

	tests := []struct {
		filters QueryFilters
		want    bool
	}{
		{QueryFilters{}, true},
		{QueryFilters{AgentName: "agent-1"}, true},
		{QueryFilters{AgentName: "agent-2"}, false},
		{QueryFilters{IssueNumber: 42}, true},
		{QueryFilters{IssueNumber: 99}, false},
		{QueryFilters{Action: ActionDispatch}, true},
		{QueryFilters{Action: ActionKill}, false},
		{QueryFilters{AgentName: "agent-1", IssueNumber: 42, Action: ActionDispatch}, true},
		{QueryFilters{AgentName: "agent-1", IssueNumber: 99}, false},
	}

	for _, tt := range tests {
		got := tt.filters.Matches(entry)
		if got != tt.want {
			t.Errorf("Matches(%+v) = %v, want %v", tt.filters, got, tt.want)
		}
	}
}

func TestSplitLines(t *testing.T) {
	tests := []struct {
		input string
		want  int
	}{
		{"", 0},
		{"line1\n", 1},
		{"line1\nline2\n", 2},
		{"line1\nline2\nline3", 3},
		{"\n\n", 0}, // empty lines ignored
	}
	for _, tt := range tests {
		lines := splitLines([]byte(tt.input))
		if len(lines) != tt.want {
			t.Errorf("splitLines(%q) = %d lines, want %d", tt.input, len(lines), tt.want)
		}
	}
}

func TestFlushNoOpWhenBucketEmpty(t *testing.T) {
	// flush() should be a no-op when bucket is empty — no aws CLI call
	tmpDir := t.TempDir()
	localPath := filepath.Join(tmpDir, "audit.jsonl")

	l := New(Config{
		AgentName:  "agent",
		Role:       "worker",
		Bucket:     "", // no S3
		LocalPath:  localPath,
		FlushEvery: time.Hour,
	}, nil)

	l.Log(ActionExit, "success", "", 0, 0)

	// Calling flush directly should not error and should leave local buffer intact
	l.flush()

	data, err := os.ReadFile(localPath)
	if err != nil {
		t.Fatalf("reading local buffer: %v", err)
	}
	if len(data) == 0 {
		t.Error("local buffer should still have data when bucket is empty (no upload)")
	}
}

// Ensure time import is used
var _ = time.Second
