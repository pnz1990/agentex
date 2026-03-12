//go:build e2e

package e2e

import (
	"testing"
	"time"
)

// TestMessageCRPosted verifies that a mock agent posts a Message CR when
// FLIGHT_MESSAGE_ENABLED=true. The message is broadcast to all peers.
func TestMessageCRPosted(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNumber = 9030
	agentName := c.Name("mock-agent-message")
	taskCRName := c.Name("task-message")

	c.CreateMockTaskCR(ctx, t, taskCRName, issueNumber, "Message CR flight test")
	c.InjectActiveAssignment(ctx, t, agentName, issueNumber)

	job := c.BuildFlightJob(agentName, taskCRName, "worker", 2, false, map[string]string{
		"FLIGHT_MESSAGE_ENABLED": "true",
		"FLIGHT_MESSAGE_TARGET":  "broadcast",
	})
	c.CreateCustomJob(ctx, t, job)
	c.Logf(t, "created flight test job %s with FLIGHT_MESSAGE_ENABLED=true", agentName)

	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 90*time.Second)
	c.Logf(t, "job %s succeeded", agentName)

	// Verify Message CR was posted.
	c.WaitForMessageCR(ctx, t, agentName, 15*time.Second)
	c.AssertMessageCRPosted(ctx, t, agentName)

	// Cleanup.
	c.DeleteAllMessageCRs(ctx, t)

	c.Logf(t, "TestMessageCRPosted passed")
}

// TestTargetedMessage verifies that a mock agent can post a targeted message
// (to a specific agent rather than broadcast).
func TestTargetedMessage(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNumber = 9031
	agentName := c.Name("mock-agent-targeted-msg")
	taskCRName := c.Name("task-targeted-msg")
	targetAgent := c.Name("mock-agent-receiver")

	c.CreateMockTaskCR(ctx, t, taskCRName, issueNumber, "Targeted message CR flight test")
	c.InjectActiveAssignment(ctx, t, agentName, issueNumber)

	job := c.BuildFlightJob(agentName, taskCRName, "worker", 2, false, map[string]string{
		"FLIGHT_MESSAGE_ENABLED": "true",
		"FLIGHT_MESSAGE_TARGET":  targetAgent,
	})
	c.CreateCustomJob(ctx, t, job)
	c.Logf(t, "created flight test job %s with targeted message to %s", agentName, targetAgent)

	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 90*time.Second)
	c.Logf(t, "job %s succeeded", agentName)

	// Verify Message CR was posted with the correct target.
	c.WaitForMessageCR(ctx, t, agentName, 15*time.Second)
	msgs := c.ListMessageCRs(ctx, t)
	found := false
	for _, m := range msgs {
		labels := m.GetLabels()
		if labels["agentex/from"] == agentName && labels["agentex/to"] == targetAgent {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("no Message CR found from %s to %s", agentName, targetAgent)
	}

	// Cleanup.
	c.DeleteAllMessageCRs(ctx, t)

	c.Logf(t, "TestTargetedMessage passed")
}
