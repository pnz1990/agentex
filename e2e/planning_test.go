//go:build e2e

package e2e

import (
	"testing"
	"time"
)

// TestPlanningStateWrittenToS3 verifies that a mock agent writes its planning state
// and swarm memory to S3 when FLIGHT_PLANNING_ENABLED and FLIGHT_SWARM_ENABLED are set.
//
// This exercises the full civilizational memory pipeline: agent completes work,
// writes planning state and swarm memory to S3, and the e2e test reads it back.
func TestPlanningStateWrittenToS3(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNumber = 9020
	agentName := c.Name("mock-agent-planning")
	taskCRName := c.Name("task-planning")

	c.CreateMockTaskCR(ctx, t, taskCRName, issueNumber, "Planning state S3 flight test")
	c.InjectActiveAssignment(ctx, t, agentName, issueNumber)

	job := c.BuildFlightJob(agentName, taskCRName, "worker", 2, false, map[string]string{
		"FLIGHT_S3_ENABLED":       "true",
		"FLIGHT_PLANNING_ENABLED": "true",
		"FLIGHT_SWARM_ENABLED":    "true",
	})
	c.CreateCustomJob(ctx, t, job)
	c.Logf(t, "created flight test job %s with S3 behaviors enabled", agentName)

	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 90*time.Second)
	c.Logf(t, "job %s succeeded", agentName)

	// Wait for planning state to appear in S3 (can take a moment after job completes).
	planningKey := "planning/" + agentName + ".json"
	c.WaitForS3Key(ctx, t, planningKey, 30*time.Second)

	// Verify planning state content.
	state := c.GetS3PlanningState(ctx, t, agentName)
	if state.AgentName != agentName {
		t.Errorf("planning state agentName=%q, want %q", state.AgentName, agentName)
	}
	if state.Role == "" {
		t.Errorf("planning state role is empty")
	}
	if state.CurrentWork == "" {
		t.Errorf("planning state currentWork is empty")
	}

	// Verify swarm memory was written.
	swarmKeys := c.ListS3SwarmMemories(ctx, t, agentName)
	if len(swarmKeys) == 0 {
		t.Errorf("expected at least one swarm memory for agent %s, got none", agentName)
	}

	// Cleanup S3.
	c.CleanupE2ES3Prefix(ctx, t, agentName)

	c.Logf(t, "TestPlanningStateWrittenToS3 passed")
}

// TestIdentityAndChronicleWrittenToS3 verifies that a mock agent writes its identity
// and chronicle candidate to S3 when the respective env vars are set.
func TestIdentityAndChronicleWrittenToS3(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNumber = 9021
	agentName := c.Name("mock-agent-identity")
	taskCRName := c.Name("task-identity")

	c.CreateMockTaskCR(ctx, t, taskCRName, issueNumber, "Identity + chronicle S3 flight test")
	c.InjectActiveAssignment(ctx, t, agentName, issueNumber)

	job := c.BuildFlightJob(agentName, taskCRName, "worker", 2, false, map[string]string{
		"FLIGHT_S3_ENABLED":        "true",
		"FLIGHT_IDENTITY_ENABLED":  "true",
		"FLIGHT_CHRONICLE_ENABLED": "true",
	})
	c.CreateCustomJob(ctx, t, job)
	c.Logf(t, "created flight test job %s with identity+chronicle S3 behaviors", agentName)

	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 90*time.Second)
	c.Logf(t, "job %s succeeded", agentName)

	// Wait for identity key in S3.
	identityKey := "identity/" + agentName + ".json"
	c.WaitForS3Key(ctx, t, identityKey, 30*time.Second)

	// Verify identity content.
	identity := c.GetS3Identity(ctx, t, agentName)
	if identity.AgentName != agentName {
		t.Errorf("identity agentName=%q, want %q", identity.AgentName, agentName)
	}
	if identity.Specialization == "" {
		t.Errorf("identity specialization is empty")
	}

	// Verify chronicle candidate was written.
	chronicleKeys := c.ListS3ChronicleCandidates(ctx, t, agentName)
	if len(chronicleKeys) == 0 {
		t.Errorf("expected at least one chronicle candidate for agent %s, got none", agentName)
	}

	// Cleanup S3.
	c.CleanupE2ES3Prefix(ctx, t, agentName)

	c.Logf(t, "TestIdentityAndChronicleWrittenToS3 passed")
}
