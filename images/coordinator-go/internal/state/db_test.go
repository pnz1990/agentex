package state_test

import (
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/pnz1990/agentex/coordinator/internal/state"
)

func newTestDB(t *testing.T) *state.DB {
	t.Helper()
	f, err := os.CreateTemp("", "agentex-test-*.db")
	if err != nil {
		t.Fatalf("create temp db: %v", err)
	}
	f.Close()
	t.Cleanup(func() { os.Remove(f.Name()) })

	db, err := state.New(f.Name())
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// ─── Task Queue Tests ─────────────────────────────────────────────────────────

func TestUpsertTask(t *testing.T) {
	db := newTestDB(t)

	task := &state.Task{
		IssueNumber: 42,
		Title:       "Test issue",
		Labels:      "bug,enhancement",
		Priority:    5,
	}
	if err := db.UpsertTask(task); err != nil {
		t.Fatalf("UpsertTask: %v", err)
	}

	tasks, err := db.GetQueuedTasks(10)
	if err != nil {
		t.Fatalf("GetQueuedTasks: %v", err)
	}
	if len(tasks) != 1 {
		t.Fatalf("expected 1 task, got %d", len(tasks))
	}
	if tasks[0].IssueNumber != 42 {
		t.Errorf("expected issue 42, got %d", tasks[0].IssueNumber)
	}
	if tasks[0].Title != "Test issue" {
		t.Errorf("expected title 'Test issue', got %q", tasks[0].Title)
	}
}

func TestUpsertTask_Idempotent(t *testing.T) {
	db := newTestDB(t)

	task := &state.Task{IssueNumber: 42, Title: "Original", Priority: 1}
	if err := db.UpsertTask(task); err != nil {
		t.Fatalf("first UpsertTask: %v", err)
	}

	// Update the title
	task.Title = "Updated"
	task.Priority = 10
	if err := db.UpsertTask(task); err != nil {
		t.Fatalf("second UpsertTask: %v", err)
	}

	tasks, _ := db.GetQueuedTasks(10)
	if len(tasks) != 1 {
		t.Fatalf("expected 1 task after upsert, got %d", len(tasks))
	}
	if tasks[0].Title != "Updated" {
		t.Errorf("expected updated title, got %q", tasks[0].Title)
	}
}

func TestClaimTask(t *testing.T) {
	db := newTestDB(t)

	// Seed task
	if err := db.UpsertTask(&state.Task{IssueNumber: 100, Title: "Claimable issue"}); err != nil {
		t.Fatalf("seed task: %v", err)
	}

	// Agent A claims the task
	claimed, err := db.ClaimTask("worker-001", 100)
	if err != nil {
		t.Fatalf("ClaimTask: %v", err)
	}
	if !claimed {
		t.Fatal("expected claim to succeed")
	}

	// Agent B tries to claim the same task — should fail
	claimed2, err := db.ClaimTask("worker-002", 100)
	if err != nil {
		t.Fatalf("ClaimTask second: %v", err)
	}
	if claimed2 {
		t.Fatal("expected second claim to fail (already claimed)")
	}

	// Verify assignment is recorded
	assignments, err := db.GetActiveAssignments()
	if err != nil {
		t.Fatalf("GetActiveAssignments: %v", err)
	}
	if len(assignments) != 1 {
		t.Fatalf("expected 1 assignment, got %d", len(assignments))
	}
	if assignments[0].AgentName != "worker-001" {
		t.Errorf("expected worker-001 assignment, got %q", assignments[0].AgentName)
	}
}

func TestClaimTask_NonExistent(t *testing.T) {
	db := newTestDB(t)
	_, err := db.ClaimTask("worker-001", 9999)
	if err == nil {
		t.Error("expected error claiming non-existent task")
	}
}

func TestReleaseTask(t *testing.T) {
	db := newTestDB(t)

	if err := db.UpsertTask(&state.Task{IssueNumber: 200, Title: "Release test"}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := db.ClaimTask("worker-001", 200); err != nil {
		t.Fatalf("claim: %v", err)
	}

	if err := db.ReleaseTask("worker-001", 200); err != nil {
		t.Fatalf("release: %v", err)
	}

	// Task should now be 'done' and not in queued list
	tasks, _ := db.GetQueuedTasks(10)
	for _, t2 := range tasks {
		if t2.IssueNumber == 200 {
			t.Errorf("released task %d should not be in queued list (state=%s)", 200, t2.State)
		}
	}
}

func TestCleanupStaleAssignments(t *testing.T) {
	db := newTestDB(t)

	if err := db.UpsertTask(&state.Task{IssueNumber: 300, Title: "Stale test"}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := db.ClaimTask("worker-stale", 300); err != nil {
		t.Fatalf("claim: %v", err)
	}

	// Cleanup with very short timeout — should immediately stale the assignment
	released, err := db.CleanupStaleAssignments(1 * time.Millisecond)
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if released != 1 {
		t.Errorf("expected 1 stale release, got %d", released)
	}

	// Task should be back in queued list (state=stale)
	tasks, _ := db.GetQueuedTasks(10)
	found := false
	for _, task := range tasks {
		if task.IssueNumber == 300 {
			found = true
			if task.State != "stale" {
				t.Errorf("expected state=stale, got %q", task.State)
			}
		}
	}
	if !found {
		t.Error("stale task should be back in queued list")
	}
}

// ─── Governance Tests ─────────────────────────────────────────────────────────

func TestRecordVote(t *testing.T) {
	db := newTestDB(t)

	vote := &state.Vote{
		Topic:     "circuit-breaker",
		AgentName: "worker-001",
		Stance:    "approve",
		Value:     "12",
		Reason:    "load rarely exceeds 10",
	}
	if err := db.RecordVote(vote); err != nil {
		t.Fatalf("RecordVote: %v", err)
	}

	count, err := db.CountApproveVotes("circuit-breaker")
	if err != nil {
		t.Fatalf("CountApproveVotes: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 approve vote, got %d", count)
	}
}

func TestRecordVote_Idempotent(t *testing.T) {
	db := newTestDB(t)

	// Same agent voting twice should only count once
	for i := 0; i < 3; i++ {
		if err := db.RecordVote(&state.Vote{
			Topic:     "circuit-breaker",
			AgentName: "worker-001",
			Stance:    "approve",
			Value:     "12",
		}); err != nil {
			t.Fatalf("RecordVote %d: %v", i, err)
		}
	}

	count, _ := db.CountApproveVotes("circuit-breaker")
	if count != 1 {
		t.Errorf("same agent should count as 1 vote, got %d", count)
	}
}

func TestVoteThreshold(t *testing.T) {
	db := newTestDB(t)

	// 3 different agents approve
	for i := 0; i < 3; i++ {
		if err := db.RecordVote(&state.Vote{
			Topic:     "circuit-breaker",
			AgentName: fmt.Sprintf("worker-%03d", i),
			Stance:    "approve",
			Value:     "8",
		}); err != nil {
			t.Fatalf("RecordVote: %v", err)
		}
	}

	count, _ := db.CountApproveVotes("circuit-breaker")
	if count != 3 {
		t.Errorf("expected 3 approve votes, got %d", count)
	}
}

func TestRecordDecision(t *testing.T) {
	db := newTestDB(t)

	decision := &state.Decision{
		Topic:        "circuit-breaker",
		Value:        "10",
		ApproveVotes: 3,
		Reason:       "governance vote",
	}
	if err := db.RecordDecision(decision); err != nil {
		t.Fatalf("RecordDecision: %v", err)
	}

	has, err := db.HasDecision("circuit-breaker")
	if err != nil {
		t.Fatalf("HasDecision: %v", err)
	}
	if !has {
		t.Error("expected HasDecision to return true after recording")
	}

	decisions, err := db.GetDecisions(10)
	if err != nil {
		t.Fatalf("GetDecisions: %v", err)
	}
	if len(decisions) != 1 {
		t.Fatalf("expected 1 decision, got %d", len(decisions))
	}
}

// ─── Debate Outcome Tests ─────────────────────────────────────────────────────

func TestRecordDebateOutcome(t *testing.T) {
	db := newTestDB(t)

	outcome := &state.DebateOutcome{
		ThreadID:     "abc123",
		Topic:        "circuit-breaker",
		Outcome:      "synthesized",
		Resolution:   "Use limit=8, reconcile every 2 min",
		Participants: `["worker-001","worker-002"]`,
		RecordedBy:   "worker-001",
	}
	if err := db.RecordDebateOutcome(outcome); err != nil {
		t.Fatalf("RecordDebateOutcome: %v", err)
	}

	results, err := db.QueryDebatesByTopic("circuit-breaker")
	if err != nil {
		t.Fatalf("QueryDebatesByTopic: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	if results[0].ThreadID != "abc123" {
		t.Errorf("expected threadId abc123, got %q", results[0].ThreadID)
	}
	if results[0].Resolution != "Use limit=8, reconcile every 2 min" {
		t.Errorf("resolution mismatch: %q", results[0].Resolution)
	}
}

func TestQueryDebatesByTopic_EmptyResult(t *testing.T) {
	db := newTestDB(t)
	results, err := db.QueryDebatesByTopic("nonexistent-topic")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(results) != 0 {
		t.Errorf("expected empty results, got %d", len(results))
	}
}

// ─── Spawn Control Tests ──────────────────────────────────────────────────────

func TestSpawnSlots(t *testing.T) {
	db := newTestDB(t)

	if err := db.SetCircuitBreakerLimit(3); err != nil {
		t.Fatalf("SetCircuitBreakerLimit: %v", err)
	}

	// Consume all 3 slots
	for i := 0; i < 3; i++ {
		granted, err := db.RequestSpawnSlot()
		if err != nil {
			t.Fatalf("RequestSpawnSlot %d: %v", i, err)
		}
		if !granted {
			t.Fatalf("slot %d should be granted", i)
		}
	}

	// 4th request should be denied
	granted, err := db.RequestSpawnSlot()
	if err != nil {
		t.Fatalf("4th RequestSpawnSlot: %v", err)
	}
	if granted {
		t.Error("4th slot should be denied (circuit breaker)")
	}

	// Release one slot
	if err := db.ReleaseSpawnSlot(); err != nil {
		t.Fatalf("ReleaseSpawnSlot: %v", err)
	}

	// Now should be granted
	granted, err = db.RequestSpawnSlot()
	if err != nil {
		t.Fatalf("RequestSpawnSlot after release: %v", err)
	}
	if !granted {
		t.Error("slot should be granted after release")
	}
}

func TestSpawnSlots_Concurrent(t *testing.T) {
	db := newTestDB(t)
	if err := db.SetCircuitBreakerLimit(5); err != nil {
		t.Fatalf("set limit: %v", err)
	}

	// Simulate 10 concurrent spawn requests — only 5 should succeed
	results := make(chan bool, 10)
	for i := 0; i < 10; i++ {
		go func() {
			granted, _ := db.RequestSpawnSlot()
			results <- granted
		}()
	}

	granted := 0
	denied := 0
	for i := 0; i < 10; i++ {
		if <-results {
			granted++
		} else {
			denied++
		}
	}

	if granted != 5 {
		t.Errorf("expected 5 granted slots, got %d (denied=%d)", granted, denied)
	}
}

// ─── KV Store Tests ───────────────────────────────────────────────────────────

func TestKVStore(t *testing.T) {
	db := newTestDB(t)

	if err := db.Set("foo", "bar"); err != nil {
		t.Fatalf("Set: %v", err)
	}

	val, err := db.Get("foo")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if val != "bar" {
		t.Errorf("expected 'bar', got %q", val)
	}

	// Update
	if err := db.Set("foo", "baz"); err != nil {
		t.Fatalf("Set update: %v", err)
	}
	val, _ = db.Get("foo")
	if val != "baz" {
		t.Errorf("expected updated 'baz', got %q", val)
	}

	// Non-existent key
	val, err = db.Get("nonexistent")
	if err != nil {
		t.Fatalf("Get nonexistent: %v", err)
	}
	if val != "" {
		t.Errorf("expected empty for nonexistent, got %q", val)
	}
}

// ─── Agent Stats Tests ────────────────────────────────────────────────────────

func TestUpsertAgentStats(t *testing.T) {
	db := newTestDB(t)

	stats := &state.AgentStats{
		AgentName:      "worker-001",
		Role:           "worker",
		Generation:     5,
		VisionScore:    8.0,
		TasksDone:      1,
		PRsOpened:      1,
		DebateCount:    2,
		Specialization: "bug-fixer",
	}
	if err := db.UpsertAgentStats(stats); err != nil {
		t.Fatalf("UpsertAgentStats: %v", err)
	}

	// Update with more work
	stats2 := &state.AgentStats{
		AgentName:   "worker-001",
		Role:        "worker",
		TasksDone:   2, // these should accumulate
		PRsOpened:   1,
		DebateCount: 1,
	}
	if err := db.UpsertAgentStats(stats2); err != nil {
		t.Fatalf("UpsertAgentStats update: %v", err)
	}
}

func TestGetDebateStats(t *testing.T) {
	db := newTestDB(t)

	// Record some votes
	stances := []string{"approve", "approve", "reject", "approve", "abstain"}
	for i, stance := range stances {
		db.RecordVote(&state.Vote{
			Topic:     fmt.Sprintf("topic-%d", i),
			AgentName: fmt.Sprintf("worker-%d", i),
			Stance:    stance,
		})
	}

	stats, err := db.GetDebateStats()
	if err != nil {
		t.Fatalf("GetDebateStats: %v", err)
	}
	if stats["approve"] != 3 {
		t.Errorf("expected 3 approve votes, got %d", stats["approve"])
	}
	if stats["reject"] != 1 {
		t.Errorf("expected 1 reject vote, got %d", stats["reject"])
	}
}
