package store_test

import (
	"os"
	"testing"
	"time"

	"github.com/pnz1990/agentex/coordinator/internal/store"
	"github.com/pnz1990/agentex/coordinator/pkg/types"
)

// newTestStore creates an in-memory SQLite store for testing.
func newTestStore(t *testing.T) *store.Store {
	t.Helper()
	// Use a temp file to avoid in-memory SQLite limitations with concurrent tests
	f, err := os.CreateTemp("", "coordinator-test-*.db")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	f.Close()
	t.Cleanup(func() { os.Remove(f.Name()) })

	s, err := store.Open(f.Name())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

// ─── Task Tests ───────────────────────────────────────────────────────────────

func TestUpsertAndListTasks(t *testing.T) {
	s := newTestStore(t)

	tasks := []*types.Task{
		{IssueNumber: 100, Title: "Task 100", Labels: "bug", Priority: 5},
		{IssueNumber: 200, Title: "Task 200", Labels: "enhancement", Priority: 10},
		{IssueNumber: 300, Title: "Task 300", Labels: "bug,security", Priority: 3},
	}

	for _, task := range tasks {
		if err := s.UpsertTask(task); err != nil {
			t.Fatalf("upsert task %d: %v", task.IssueNumber, err)
		}
	}

	pending, err := s.ListPendingTasks(10)
	if err != nil {
		t.Fatalf("list pending: %v", err)
	}
	if len(pending) != 3 {
		t.Fatalf("expected 3 pending tasks, got %d", len(pending))
	}

	// Verify ordering: highest priority first
	if pending[0].IssueNumber != 200 {
		t.Errorf("expected task 200 first (priority 10), got %d", pending[0].IssueNumber)
	}
	if pending[1].IssueNumber != 100 {
		t.Errorf("expected task 100 second (priority 5), got %d", pending[1].IssueNumber)
	}
}

func TestClaimTask_Atomic(t *testing.T) {
	s := newTestStore(t)

	task := &types.Task{IssueNumber: 42, Title: "Implement feature", Priority: 5}
	if err := s.UpsertTask(task); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	// First claim should succeed
	claimed, ok, err := s.ClaimTask(42, "worker-001")
	if err != nil {
		t.Fatalf("claim 1: %v", err)
	}
	if !ok {
		t.Fatal("expected claim to succeed")
	}
	if claimed.AgentName != "worker-001" {
		t.Errorf("expected agent worker-001, got %s", claimed.AgentName)
	}
	if claimed.Status != types.TaskStatusClaimed {
		t.Errorf("expected status claimed, got %s", claimed.Status)
	}

	// Second claim by different agent should fail
	_, ok2, err := s.ClaimTask(42, "worker-002")
	if err != nil {
		t.Fatalf("claim 2: %v", err)
	}
	if ok2 {
		t.Fatal("expected second claim to fail — task already claimed")
	}
}

func TestClaimTask_NotInQueue(t *testing.T) {
	s := newTestStore(t)

	_, ok, err := s.ClaimTask(9999, "worker-001")
	if err != nil {
		t.Fatalf("claim: %v", err)
	}
	if ok {
		t.Fatal("expected claim to fail for non-existent task")
	}
}

func TestReleaseTask(t *testing.T) {
	s := newTestStore(t)

	task := &types.Task{IssueNumber: 55, Title: "Test task", Priority: 5}
	if err := s.UpsertTask(task); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	if _, _, err := s.ClaimTask(55, "worker-001"); err != nil {
		t.Fatalf("claim: %v", err)
	}

	if err := s.ReleaseTask(55, "worker-001", types.TaskStatusDone); err != nil {
		t.Fatalf("release: %v", err)
	}

	// Claimed task is done, should not appear in pending
	pending, err := s.ListPendingTasks(10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	for _, p := range pending {
		if p.IssueNumber == 55 {
			t.Error("done task should not appear in pending list")
		}
	}
}

func TestGetStaleAssignments(t *testing.T) {
	s := newTestStore(t)

	task := &types.Task{IssueNumber: 77, Title: "Stale task", Priority: 5}
	if err := s.UpsertTask(task); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	if _, _, err := s.ClaimTask(77, "worker-stale"); err != nil {
		t.Fatalf("claim: %v", err)
	}

	// With a very short timeout, the task should immediately be stale
	stale, err := s.GetStaleAssignments(0)
	if err != nil {
		t.Fatalf("get stale: %v", err)
	}
	if len(stale) == 0 {
		t.Fatal("expected stale task, got none")
	}

	// Reclaim it
	if err := s.ReclaimStaleTask(stale[0].ID); err != nil {
		t.Fatalf("reclaim: %v", err)
	}

	// Should be back in pending
	pending, err := s.ListPendingTasks(10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	found := false
	for _, p := range pending {
		if p.IssueNumber == 77 {
			found = true
		}
	}
	if !found {
		t.Error("reclaimed task should be back in pending")
	}
}

// ─── Vote Tests ───────────────────────────────────────────────────────────────

func TestVoteTallying(t *testing.T) {
	s := newTestStore(t)

	votes := []*types.Vote{
		{Topic: "circuit-breaker", ProposalID: "prop-001", AgentName: "agent-a", Status: types.VoteApprove, Value: "circuitBreakerLimit=12"},
		{Topic: "circuit-breaker", ProposalID: "prop-001", AgentName: "agent-b", Status: types.VoteApprove, Value: "circuitBreakerLimit=12"},
		{Topic: "circuit-breaker", ProposalID: "prop-001", AgentName: "agent-c", Status: types.VoteReject, Value: ""},
		{Topic: "circuit-breaker", ProposalID: "prop-001", AgentName: "agent-d", Status: types.VoteApprove, Value: "circuitBreakerLimit=12"},
	}

	for _, v := range votes {
		if err := s.RecordVote(v); err != nil {
			t.Fatalf("record vote: %v", err)
		}
	}

	approve, reject, abstain, err := s.TallyVotes("circuit-breaker")
	if err != nil {
		t.Fatalf("tally: %v", err)
	}
	if approve != 3 {
		t.Errorf("expected 3 approvals, got %d", approve)
	}
	if reject != 1 {
		t.Errorf("expected 1 rejection, got %d", reject)
	}
	if abstain != 0 {
		t.Errorf("expected 0 abstentions, got %d", abstain)
	}
}

func TestVote_OnePerAgent(t *testing.T) {
	s := newTestStore(t)

	// Agent votes approve then changes to reject
	v1 := &types.Vote{Topic: "test-topic", ProposalID: "p1", AgentName: "agent-x", Status: types.VoteApprove}
	v2 := &types.Vote{Topic: "test-topic", ProposalID: "p1", AgentName: "agent-x", Status: types.VoteReject}

	if err := s.RecordVote(v1); err != nil {
		t.Fatalf("vote 1: %v", err)
	}
	if err := s.RecordVote(v2); err != nil {
		t.Fatalf("vote 2: %v", err)
	}

	approve, reject, _, err := s.TallyVotes("test-topic")
	if err != nil {
		t.Fatalf("tally: %v", err)
	}
	if approve != 0 {
		t.Errorf("expected 0 approvals after change to reject, got %d", approve)
	}
	if reject != 1 {
		t.Errorf("expected 1 rejection, got %d", reject)
	}
}

// ─── Spawn Slot Tests ─────────────────────────────────────────────────────────

func TestSpawnSlot_CircuitBreaker(t *testing.T) {
	s := newTestStore(t)
	limit := 3

	// Fill up all slots
	for i := 0; i < limit; i++ {
		agentName := "agent-" + string(rune('a'+i))
		allowed, err := s.AllocateSpawnSlot(agentName, "worker", limit)
		if err != nil {
			t.Fatalf("allocate slot %d: %v", i, err)
		}
		if !allowed {
			t.Fatalf("slot %d should be allowed (limit %d)", i, limit)
		}
	}

	// Circuit breaker should now block
	allowed, err := s.AllocateSpawnSlot("agent-overflow", "worker", limit)
	if err != nil {
		t.Fatalf("allocate overflow: %v", err)
	}
	if allowed {
		t.Error("overflow spawn should be blocked by circuit breaker")
	}

	// Release a slot
	if err := s.ReleaseSpawnSlot("agent-a"); err != nil {
		t.Fatalf("release: %v", err)
	}

	// Should now be allowed again
	allowed, err = s.AllocateSpawnSlot("agent-new", "worker", limit)
	if err != nil {
		t.Fatalf("allocate after release: %v", err)
	}
	if !allowed {
		t.Error("spawn should be allowed after slot release")
	}
}

func TestSpawnSlot_ActiveCount(t *testing.T) {
	s := newTestStore(t)

	count, err := s.GetActiveSpawnCount()
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 0 {
		t.Errorf("expected 0 active slots, got %d", count)
	}

	s.AllocateSpawnSlot("agent-1", "worker", 10)
	s.AllocateSpawnSlot("agent-2", "worker", 10)

	count, err = s.GetActiveSpawnCount()
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 2 {
		t.Errorf("expected 2 active slots, got %d", count)
	}
}

// ─── Debate Tests ─────────────────────────────────────────────────────────────

func TestDebateOutcomes(t *testing.T) {
	s := newTestStore(t)

	outcome := &types.DebateOutcome{
		ThreadID:     "abc123",
		Topic:        "circuit-breaker",
		Outcome:      "synthesized",
		Resolution:   "reduce TTL to 240s",
		Participants: `["agent-a","agent-b"]`,
		RecordedBy:   "agent-b",
	}

	if err := s.UpsertDebateOutcome(outcome); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	results, err := s.QueryDebateOutcomes("circuit-breaker")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	if results[0].Resolution != "reduce TTL to 240s" {
		t.Errorf("unexpected resolution: %s", results[0].Resolution)
	}

	// Query all (empty topic)
	all, err := s.QueryDebateOutcomes("")
	if err != nil {
		t.Fatalf("query all: %v", err)
	}
	if len(all) != 1 {
		t.Fatalf("expected 1 total result, got %d", len(all))
	}

	// Upsert should update, not duplicate
	outcome.Resolution = "updated resolution"
	if err := s.UpsertDebateOutcome(outcome); err != nil {
		t.Fatalf("upsert update: %v", err)
	}
	results2, _ := s.QueryDebateOutcomes("")
	if len(results2) != 1 {
		t.Fatalf("upsert should update, not duplicate — got %d", len(results2))
	}
	if results2[0].Resolution != "updated resolution" {
		t.Errorf("expected updated resolution, got %s", results2[0].Resolution)
	}
}

// ─── Config Tests ─────────────────────────────────────────────────────────────

func TestConfig_SetGet(t *testing.T) {
	s := newTestStore(t)

	if err := s.SetConfig("generation", "4"); err != nil {
		t.Fatalf("set: %v", err)
	}

	val, err := s.GetConfig("generation")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if val != "4" {
		t.Errorf("expected 4, got %s", val)
	}

	// Overwrite
	if err := s.SetConfig("generation", "5"); err != nil {
		t.Fatalf("set 2: %v", err)
	}
	val2, _ := s.GetConfig("generation")
	if val2 != "5" {
		t.Errorf("expected 5 after update, got %s", val2)
	}
}

func TestConfig_Missing(t *testing.T) {
	s := newTestStore(t)
	val, err := s.GetConfig("nonexistent")
	if err != nil {
		t.Fatalf("get missing: %v", err)
	}
	if val != "" {
		t.Errorf("expected empty string for missing key, got %q", val)
	}
}

// ─── Agent Tests ──────────────────────────────────────────────────────────────

func TestAgentRegistration(t *testing.T) {
	s := newTestStore(t)

	agent := &types.Agent{
		Name:           "worker-001",
		Role:           types.RoleWorker,
		Generation:     4,
		DisplayName:    "Ada",
		Specialization: "debugger",
	}

	if err := s.UpsertAgent(agent); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	count, err := s.GetActiveAgentCount()
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 active agent, got %d", count)
	}

	// Heartbeat (same agent, update last_seen_at)
	agent.LastSeenAt = time.Now()
	if err := s.UpsertAgent(agent); err != nil {
		t.Fatalf("heartbeat: %v", err)
	}

	count2, _ := s.GetActiveAgentCount()
	if count2 != 1 {
		t.Errorf("heartbeat should not create duplicate, got count %d", count2)
	}

	// Mark inactive
	if err := s.MarkAgentInactive("worker-001"); err != nil {
		t.Fatalf("deregister: %v", err)
	}
	count3, _ := s.GetActiveAgentCount()
	if count3 != 0 {
		t.Errorf("expected 0 active after deregister, got %d", count3)
	}
}

func TestFindSpecializedAgent(t *testing.T) {
	s := newTestStore(t)

	agents := []*types.Agent{
		{Name: "worker-a", Role: types.RoleWorker, Specialization: "debugger"},
		{Name: "worker-b", Role: types.RoleWorker, Specialization: "platform-specialist"},
		{Name: "worker-c", Role: types.RoleWorker, Specialization: "security"},
	}
	for _, a := range agents {
		s.UpsertAgent(a)
	}

	found, err := s.FindSpecializedAgent("security")
	if err != nil {
		t.Fatalf("find: %v", err)
	}
	if found == nil {
		t.Fatal("expected to find specialized agent")
	}
	if found.Name != "worker-c" {
		t.Errorf("expected worker-c, got %s", found.Name)
	}

	// Non-existent specialization
	notFound, err := s.FindSpecializedAgent("nonexistent-specialization")
	if err != nil {
		t.Fatalf("find none: %v", err)
	}
	if notFound != nil {
		t.Error("expected nil for missing specialization")
	}
}
