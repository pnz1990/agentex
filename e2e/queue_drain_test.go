//go:build e2e

package e2e

import (
	"fmt"
	"testing"
	"time"
)

// TestQueueDrain verifies that when N issues are in the coordinator task queue
// and N mock agents are dispatched one-by-one, the queue drains fully.
//
// Scenario:
//  1. Inject 5 issues into the task queue.
//  2. For each issue: create a Task CR, inject an assignment, create a Job.
//  3. Remove each issue from the queue (simulating coordinator dispatch).
//  4. Wait for all Jobs to complete.
//  5. Assert the queue is empty and no assignments remain.
func TestQueueDrain(t *testing.T) {
	c, ctx := newCluster(t)

	const issueCount = 5
	const baseIssue = 9300

	// Step 1: inject all issues into the queue.
	issues := make([]int, issueCount)
	for i := range issueCount {
		issues[i] = baseIssue + i
	}
	c.InjectTaskQueue(ctx, t, issues)
	c.AssertQueueContains(ctx, t, issues...)
	c.Logf(t, "injected %d issues into task queue", issueCount)

	// Step 2: simulate coordinator dispatch — create Task CRs, assignments, and Jobs.
	for i, issueNum := range issues {
		agentName := c.Name(fmt.Sprintf("mock-drain-agent-%d", i))
		taskName := c.Name(fmt.Sprintf("task-drain-%d", issueNum))

		c.CreateMockTaskCR(ctx, t, taskName, issueNum, fmt.Sprintf("queue drain test issue #%d", issueNum))
		c.InjectActiveAssignment(ctx, t, agentName, issueNum)
		c.CreateMockAgentJob(ctx, t, agentName, taskName, "worker", 3, false)
		c.Logf(t, "dispatched agent %s for issue #%d", agentName, issueNum)
	}

	// Step 3: clear the task queue (coordinator would do this on dispatch).
	c.InjectTaskQueue(ctx, t, []int{})
	c.AssertQueueEmpty(ctx, t)
	c.Logf(t, "task queue cleared after dispatch")

	// Step 4: wait for all Jobs to complete.
	for i := range issueCount {
		agentName := c.Name(fmt.Sprintf("mock-drain-agent-%d", i))
		c.WaitForJobStatus(ctx, t, agentName, "succeeded", 60*time.Second)
		c.Logf(t, "agent %s completed", agentName)
	}

	// Step 5: all assignments should be released by coordinator cleanup.
	for i := range issueCount {
		agentName := c.Name(fmt.Sprintf("mock-drain-agent-%d", i))
		c.WaitForAssignmentReleased(ctx, t, agentName, 90*time.Second)
	}
	c.AssertAssignmentCount(ctx, t, 0)
	c.AssertQueueEmpty(ctx, t)

	c.Logf(t, "TestQueueDrain passed: all %d agents completed, queue drained, assignments cleared", issueCount)
}

// TestQueueDrain_PartialFailure verifies that when some agents fail, the queue
// remains drained but failed agents' assignments are still released.
func TestQueueDrain_PartialFailure(t *testing.T) {
	c, ctx := newCluster(t)

	const issueCount = 4
	const baseIssue = 9350

	issues := make([]int, issueCount)
	for i := range issueCount {
		issues[i] = baseIssue + i
	}
	c.InjectTaskQueue(ctx, t, issues)

	for i, issueNum := range issues {
		agentName := c.Name(fmt.Sprintf("mock-pf-agent-%d", i))
		taskName := c.Name(fmt.Sprintf("task-pf-%d", issueNum))
		// Every other agent fails.
		fail := i%2 == 1

		c.CreateMockTaskCR(ctx, t, taskName, issueNum, fmt.Sprintf("partial failure test #%d", issueNum))
		c.InjectActiveAssignment(ctx, t, agentName, issueNum)
		c.CreateMockAgentJob(ctx, t, agentName, taskName, "worker", 2, fail)
		c.Logf(t, "dispatched agent %s (fail=%v)", agentName, fail)
	}

	c.InjectTaskQueue(ctx, t, []int{})

	// All Jobs should reach terminal state (succeeded or failed).
	for i := range issueCount {
		agentName := c.Name(fmt.Sprintf("mock-pf-agent-%d", i))
		// The mock agent exits 0 even when MockFail=true (posts Report and exits cleanly).
		c.WaitForJobStatus(ctx, t, agentName, "succeeded", 60*time.Second)
	}

	// All assignments released.
	for i := range issueCount {
		agentName := c.Name(fmt.Sprintf("mock-pf-agent-%d", i))
		c.WaitForAssignmentReleased(ctx, t, agentName, 90*time.Second)
	}
	c.AssertAssignmentCount(ctx, t, 0)

	c.Logf(t, "TestQueueDrain_PartialFailure passed")
}
