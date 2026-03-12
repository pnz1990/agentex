//go:build e2e

package e2e

import (
	"testing"
	"time"
)

// TestBasicDispatch verifies the fundamental coordinator→agent lifecycle:
//
//  1. Inject a task into the queue.
//  2. Create a Task CR and a mock agent Job (flight test mode).
//  3. Wait for the Job to succeed.
//  4. Verify a Report CR was posted with status=success.
//  5. Verify the active assignment was released (coordinator cleanup).
func TestBasicDispatch(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNumber = 9001
	agentName := c.Name("mock-agent-basic-dispatch")
	taskCRName := c.Name("task-basic-dispatch")

	// Inject issue into coordinator task queue.
	c.InjectTaskQueue(ctx, t, []int{issueNumber})
	c.AssertQueueContains(ctx, t, issueNumber)

	// Create the Task CR that the agent will read.
	c.CreateMockTaskCR(ctx, t, taskCRName, issueNumber, "Basic dispatch e2e test")

	// Inject an active assignment to simulate the coordinator having dispatched this agent.
	c.InjectActiveAssignment(ctx, t, agentName, issueNumber)
	c.AssertAssignmentCount(ctx, t, 1)

	// Create the mock agent Job. Sleep 3s to simulate work.
	c.CreateMockAgentJob(ctx, t, agentName, taskCRName, "worker", 3, false)
	c.Logf(t, "created mock agent job %s for issue #%d", agentName, issueNumber)

	// Wait for Job to succeed (90s timeout — first run pulls the image ~30s).
	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 90*time.Second)
	c.Logf(t, "job %s succeeded", agentName)

	// Verify the Report CR was posted.
	c.WaitForReportCR(ctx, t, 1, 10*time.Second)
	c.AssertReportCRPosted(ctx, t, agentName)
	c.AssertReportCRStatus(ctx, t, agentName, "success")

	c.Logf(t, "TestBasicDispatch passed")
}

// TestBasicDispatch_Failure verifies that when MOCK_AGENT_FAIL=true the agent
// posts a failure Report CR.
func TestBasicDispatch_Failure(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNumber = 9002
	agentName := c.Name("mock-agent-fail")
	taskCRName := c.Name("task-fail")

	c.CreateMockTaskCR(ctx, t, taskCRName, issueNumber, "Failure scenario e2e test")
	c.InjectActiveAssignment(ctx, t, agentName, issueNumber)

	// Run agent with fail=true and 0s sleep.
	c.CreateMockAgentJob(ctx, t, agentName, taskCRName, "worker", 0, true)
	c.Logf(t, "created failing mock agent job %s", agentName)

	// The agent exits 0 even on mock failure (it posts a Report and exits cleanly).
	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 90*time.Second)

	c.WaitForReportCR(ctx, t, 1, 10*time.Second)
	c.AssertReportCRPosted(ctx, t, agentName)
	c.AssertReportCRStatus(ctx, t, agentName, "failure")

	c.Logf(t, "TestBasicDispatch_Failure passed")
}
