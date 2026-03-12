//go:build e2e

package e2e

import (
	"testing"
	"time"
)

// TestThoughtCRsPosted verifies that a mock agent posts Thought CRs during flight test execution.
//
// The test enables FLIGHT_THOUGHT_COUNT=3 and verifies that exactly 3 Thought CRs
// are created in the namespace, including the expected types (insight, observation, concern).
func TestThoughtCRsPosted(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNumber = 9010
	agentName := c.Name("mock-agent-thoughts")
	taskCRName := c.Name("task-thoughts")

	c.CreateMockTaskCR(ctx, t, taskCRName, issueNumber, "Thought CR flight test")
	c.InjectActiveAssignment(ctx, t, agentName, issueNumber)

	// Create job with FLIGHT_THOUGHT_COUNT=3 to post 3 thoughts.
	job := c.BuildFlightJob(agentName, taskCRName, "worker", 2, false, map[string]string{
		"FLIGHT_THOUGHT_COUNT": "3",
	})
	c.CreateCustomJob(ctx, t, job)
	c.Logf(t, "created flight test job %s with FLIGHT_THOUGHT_COUNT=3", agentName)

	// Wait for the job to complete.
	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 90*time.Second)
	c.Logf(t, "job %s succeeded", agentName)

	// Verify Thought CRs were posted.
	c.WaitForThoughtCRs(ctx, t, agentName, 3, 15*time.Second)
	c.AssertThoughtCRCount(ctx, t, agentName, 3)
	c.AssertThoughtCRTypes(ctx, t, agentName, "insight", "observation", "concern")

	// Verify content references the correct issue.
	c.AssertThoughtContentContains(ctx, t, agentName, "issue #9010")

	// Cleanup thought CRs.
	c.DeleteAllThoughtCRs(ctx, t)

	c.Logf(t, "TestThoughtCRsPosted passed")
}

// TestDebateThoughtPosted verifies that a mock agent posts a debate vote Thought CR
// when FLIGHT_DEBATE_ENABLED=true.
func TestDebateThoughtPosted(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNumber = 9011
	agentName := c.Name("mock-agent-debate")
	taskCRName := c.Name("task-debate")

	c.CreateMockTaskCR(ctx, t, taskCRName, issueNumber, "Debate flight test")
	c.InjectActiveAssignment(ctx, t, agentName, issueNumber)

	// Enable debate mode — agent should post a "vote" type thought.
	job := c.BuildFlightJob(agentName, taskCRName, "worker", 2, false, map[string]string{
		"FLIGHT_THOUGHT_COUNT":  "2",
		"FLIGHT_DEBATE_ENABLED": "true",
	})
	c.CreateCustomJob(ctx, t, job)
	c.Logf(t, "created flight test job %s with FLIGHT_DEBATE_ENABLED=true", agentName)

	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 90*time.Second)
	c.Logf(t, "job %s succeeded", agentName)

	// Should have 2 regular + 1 debate = 3 thoughts total.
	c.WaitForThoughtCRs(ctx, t, agentName, 3, 15*time.Second)
	c.AssertThoughtCRCount(ctx, t, agentName, 3)
	c.AssertDebateThought(ctx, t, agentName)

	c.DeleteAllThoughtCRs(ctx, t)
	c.Logf(t, "TestDebateThoughtPosted passed")
}
