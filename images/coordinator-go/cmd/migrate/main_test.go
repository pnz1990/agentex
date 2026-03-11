package main

import (
	"testing"
)

// TestBuildMigrationPlan_TaskQueue verifies that taskQueue is correctly parsed.
func TestBuildMigrationPlan_TaskQueue(t *testing.T) {
	state := map[string]string{
		"taskQueue": "1782,1783,1799",
	}
	plan := buildMigrationPlan(state, map[string]string{})

	if got := len(plan.Tasks); got != 3 {
		t.Errorf("expected 3 tasks, got %d", got)
	}
	for i, want := range []int{1782, 1783, 1799} {
		if plan.Tasks[i].IssueNumber != want {
			t.Errorf("tasks[%d].IssueNumber = %d, want %d", i, plan.Tasks[i].IssueNumber, want)
		}
		if plan.Tasks[i].State != "queued" {
			t.Errorf("tasks[%d].State = %q, want %q", i, plan.Tasks[i].State, "queued")
		}
	}
}

// TestBuildMigrationPlan_ActiveAssignments verifies that activeAssignments
// moves queued tasks to claimed and sets ClaimedBy.
func TestBuildMigrationPlan_ActiveAssignments(t *testing.T) {
	state := map[string]string{
		"taskQueue":         "1782,1783",
		"activeAssignments": "worker-abc:1782,worker-xyz:1800",
	}
	plan := buildMigrationPlan(state, map[string]string{})

	// 1782 should be claimed (was in taskQueue first)
	// 1783 should stay queued
	// 1800 should be claimed (new entry only in activeAssignments)
	found := map[int]taskRow{}
	for _, t := range plan.Tasks {
		found[t.IssueNumber] = t
	}

	if len(plan.Tasks) != 3 {
		t.Fatalf("expected 3 tasks, got %d", len(plan.Tasks))
	}

	if r := found[1782]; r.State != "claimed" || r.ClaimedBy != "worker-abc" {
		t.Errorf("task 1782: state=%q claimedBy=%q, want claimed/worker-abc", r.State, r.ClaimedBy)
	}
	if r := found[1783]; r.State != "queued" {
		t.Errorf("task 1783: state=%q, want queued", r.State)
	}
	if r := found[1800]; r.State != "claimed" || r.ClaimedBy != "worker-xyz" {
		t.Errorf("task 1800: state=%q claimedBy=%q, want claimed/worker-xyz", r.State, r.ClaimedBy)
	}
}

// TestBuildMigrationPlan_ActiveAgents verifies agent parsing.
func TestBuildMigrationPlan_ActiveAgents(t *testing.T) {
	state := map[string]string{
		"activeAgents": "worker-abc:worker,planner-001:planner",
	}
	plan := buildMigrationPlan(state, map[string]string{})

	if got := len(plan.Agents); got != 2 {
		t.Fatalf("expected 2 agents, got %d", got)
	}
	if plan.Agents[0].Name != "worker-abc" || plan.Agents[0].Role != "worker" {
		t.Errorf("agent[0] = %+v, want {worker-abc worker active}", plan.Agents[0])
	}
	if plan.Agents[1].Name != "planner-001" || plan.Agents[1].Role != "planner" {
		t.Errorf("agent[1] = %+v, want {planner-001 planner active}", plan.Agents[1])
	}
}

// TestBuildMigrationPlan_VisionQueue verifies all visionQueue format variants.
func TestBuildMigrationPlan_VisionQueue(t *testing.T) {
	state := map[string]string{
		// feature:description:ts:proposer format
		"visionQueue": "mentorship-chains:predecessor-identity-passed-to-workers:2026-03-10T00:00:00Z:planner-001;" +
			// plain issue number
			"1219;" +
			// feature only
			"my-feature",
	}
	plan := buildMigrationPlan(state, map[string]string{})

	if got := len(plan.VisionQueue); got != 3 {
		t.Fatalf("expected 3 vision entries, got %d", got)
	}
	if plan.VisionQueue[0].FeatureName != "mentorship-chains" {
		t.Errorf("visionQueue[0].FeatureName = %q, want mentorship-chains", plan.VisionQueue[0].FeatureName)
	}
	if plan.VisionQueue[0].ProposedBy != "planner-001" {
		t.Errorf("visionQueue[0].ProposedBy = %q, want planner-001", plan.VisionQueue[0].ProposedBy)
	}
	if plan.VisionQueue[1].IssueNumber != 1219 {
		t.Errorf("visionQueue[1].IssueNumber = %d, want 1219", plan.VisionQueue[1].IssueNumber)
	}
	if plan.VisionQueue[2].FeatureName != "my-feature" {
		t.Errorf("visionQueue[2].FeatureName = %q, want my-feature", plan.VisionQueue[2].FeatureName)
	}
}

// TestBuildMigrationPlan_EnactedDecisions verifies constitution_log parsing.
func TestBuildMigrationPlan_EnactedDecisions(t *testing.T) {
	state := map[string]string{
		"enactedDecisions": "circuitBreakerLimit=6|2026-03-09T12:00:00Z|4-votes",
	}
	plan := buildMigrationPlan(state, map[string]string{})

	if got := len(plan.Constitution); got != 1 {
		t.Fatalf("expected 1 constitution row, got %d", got)
	}
	if plan.Constitution[0].Key != "circuitBreakerLimit" || plan.Constitution[0].NewValue != "6" {
		t.Errorf("constitution[0] = {%s=%s}, want circuitBreakerLimit=6",
			plan.Constitution[0].Key, plan.Constitution[0].NewValue)
	}
}

// TestBuildMigrationPlan_ConstitutionConfigMap verifies that the constitution
// ConfigMap's circuitBreakerLimit is imported into constitution_log.
func TestBuildMigrationPlan_ConstitutionConfigMap(t *testing.T) {
	state := map[string]string{}
	constitution := map[string]string{
		"circuitBreakerLimit": "10",
	}
	plan := buildMigrationPlan(state, constitution)

	if got := len(plan.Constitution); got != 1 {
		t.Fatalf("expected 1 constitution row, got %d", got)
	}
	if plan.Constitution[0].NewValue != "10" {
		t.Errorf("constitution[0].NewValue = %q, want 10", plan.Constitution[0].NewValue)
	}
}

// TestBuildMigrationPlan_DebateStats verifies metric parsing from debateStats.
func TestBuildMigrationPlan_DebateStats(t *testing.T) {
	state := map[string]string{
		"debateStats": "responses=738 threads=666 disagree=184 synthesize=202",
	}
	plan := buildMigrationPlan(state, map[string]string{})

	metrics := map[string]int{}
	for _, m := range plan.Metrics {
		metrics[m.Metric] = m.Value
	}

	expected := map[string]int{
		"debate_responses":  738,
		"debate_threads":    666,
		"debate_disagree":   184,
		"debate_synthesize": 202,
	}
	for k, want := range expected {
		if got := metrics[k]; got != want {
			t.Errorf("metric %q = %d, want %d", k, got, want)
		}
	}
}

// TestBuildMigrationPlan_Counters verifies specializedAssignments import.
func TestBuildMigrationPlan_Counters(t *testing.T) {
	state := map[string]string{
		"specializedAssignments": "42",
		"genericAssignments":     "365",
	}
	plan := buildMigrationPlan(state, map[string]string{})

	metrics := map[string]int{}
	for _, m := range plan.Metrics {
		metrics[m.Metric] = m.Value
	}
	if got := metrics["specialized_assignments"]; got != 42 {
		t.Errorf("specialized_assignments = %d, want 42", got)
	}
	if got := metrics["generic_assignments"]; got != 365 {
		t.Errorf("generic_assignments = %d, want 365", got)
	}
}

// TestNormalizeRole verifies that known and unknown roles map correctly.
func TestNormalizeRole(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"worker", "worker"},
		{"planner", "planner"},
		{"reviewer", "reviewer"},
		{"architect", "architect"},
		{"god-delegate", "god-delegate"},
		{"god_delegate", "god-delegate"},
		{"GodDelegate", "worker"}, // unknown → fallback
		{"critic", "critic"},
		{"unknown-role", "worker"}, // fallback
	}
	for _, c := range cases {
		if got := normalizeRole(c.in); got != c.want {
			t.Errorf("normalizeRole(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestCamelToSnake verifies the camelCase → snake_case conversion.
func TestCamelToSnake(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"specializedAssignments", "specialized_assignments"},
		{"genericAssignments", "generic_assignments"},
		{"debateStats", "debate_stats"},
		{"alreadylower", "alreadylower"},
	}
	for _, c := range cases {
		if got := camelToSnake(c.in); got != c.want {
			t.Errorf("camelToSnake(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestMigrationPlan_EmptyInputs verifies graceful handling of empty/missing fields.
func TestMigrationPlan_EmptyInputs(t *testing.T) {
	plan := buildMigrationPlan(map[string]string{}, map[string]string{})

	if len(plan.Tasks) != 0 {
		t.Errorf("expected 0 tasks for empty input, got %d", len(plan.Tasks))
	}
	if len(plan.Agents) != 0 {
		t.Errorf("expected 0 agents for empty input, got %d", len(plan.Agents))
	}
	if len(plan.VisionQueue) != 0 {
		t.Errorf("expected 0 vision entries for empty input, got %d", len(plan.VisionQueue))
	}
	if len(plan.Metrics) != 0 {
		t.Errorf("expected 0 metrics for empty input, got %d", len(plan.Metrics))
	}
}

// TestBuildMigrationPlan_SpacePaddedAssignments verifies that space-padded
// activeAssignments entries (known issue #1488) are handled correctly.
func TestBuildMigrationPlan_SpacePaddedAssignments(t *testing.T) {
	state := map[string]string{
		// Space after agent name and before comma (mirroring coordinator-state bug)
		"activeAssignments": "worker-abc :1782 ,worker-xyz :1800 ",
	}
	plan := buildMigrationPlan(state, map[string]string{})

	found := map[int]taskRow{}
	for _, t := range plan.Tasks {
		found[t.IssueNumber] = t
	}

	if _, ok := found[1782]; !ok {
		t.Errorf("expected task 1782 to be imported despite space padding")
	}
	if _, ok := found[1800]; !ok {
		t.Errorf("expected task 1800 to be imported despite space padding")
	}
}

// TestMigrationPlan_Summary verifies that Summary() returns non-empty lines.
func TestMigrationPlan_Summary(t *testing.T) {
	plan := buildMigrationPlan(map[string]string{
		"taskQueue":         "1,2",
		"activeAssignments": "worker-a:3",
		"activeAgents":      "worker-a:worker",
	}, map[string]string{})

	lines := plan.Summary()
	if len(lines) == 0 {
		t.Error("Summary() returned no lines")
	}
	for _, line := range lines {
		if line == "" {
			t.Error("Summary() returned empty line")
		}
	}
}
