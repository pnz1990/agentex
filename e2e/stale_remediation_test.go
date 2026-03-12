//go:build e2e

package e2e

import (
	"fmt"
	"testing"
	"time"
)

// TestStaleRemediation verifies that the coordinator's remediator releases
// stale assignments for agents whose Jobs no longer exist.
//
// Scenario:
//  1. Inject two "stale" active assignments (no corresponding Jobs).
//  2. Wait for the coordinator's cleanupStaleAssignments() to run (~30s tick).
//  3. Assert both assignments are gone.
func TestStaleRemediation(t *testing.T) {
	c, ctx := newCluster(t)

	// Inject stale assignments — no Jobs exist for these agents.
	staleAgent1 := c.Name("stale-ghost-agent-1")
	staleAgent2 := c.Name("stale-ghost-agent-2")
	c.InjectActiveAssignment(ctx, t, staleAgent1, 9200)
	c.InjectActiveAssignment(ctx, t, staleAgent2, 9201)
	c.AssertAssignmentCount(ctx, t, 2)
	c.Logf(t, "injected 2 stale assignments (no Jobs backing them)")

	// Wait for coordinator to detect and release them.
	// cleanupStaleAssignments runs every tick (30s default).
	// We wait up to 90s to allow for coordinator startup + 2 ticks.
	c.WaitForAssignmentReleased(ctx, t, staleAgent1, 90*time.Second)
	c.WaitForAssignmentReleased(ctx, t, staleAgent2, 90*time.Second)

	c.AssertAssignmentCount(ctx, t, 0)
	c.Logf(t, "TestStaleRemediation passed: both stale assignments released")
}

// TestStaleRemediation_ActiveKept verifies that assignments for running Jobs
// are NOT released by the remediator.
//
// Scenario:
//  1. Create a real mock agent Job (sleeping 20s).
//  2. Inject an active assignment for it.
//  3. Wait one tick interval (35s).
//  4. Assert the assignment is still present.
//  5. Wait for Job to complete, then assert assignment is released.
func TestStaleRemediation_ActiveKept(t *testing.T) {
	c, ctx := newCluster(t)

	const issueNum = 9210
	agentName := c.Name(fmt.Sprintf("mock-active-agent-%d", issueNum))
	taskName := c.Name(fmt.Sprintf("task-active-%d", issueNum))

	c.CreateMockTaskCR(ctx, t, taskName, issueNum, "stale remediation active kept test")

	// Create the Job BEFORE injecting the assignment so the coordinator's first
	// stale-cleanup tick sees an active Job for this agent and doesn't release it.
	c.CreateMockAgentJob(ctx, t, agentName, taskName, "worker", 20, false)
	c.Logf(t, "created active agent %s with 20s sleep", agentName)

	// Wait for the Job to actually be active before we inject the assignment.
	// This closes the race: coordinator tick fires → checks job → job not yet running
	// → releases assignment as stale.
	c.WaitForJobStatus(ctx, t, agentName, "active", 30*time.Second)

	// Now inject the assignment — coordinator will see an active Job and keep it.
	c.InjectActiveAssignment(ctx, t, agentName, issueNum)

	// Wait one full coordinator tick interval (15s heartbeat + margin = 20s).
	// The assignment should still be there because the Job is active.
	time.Sleep(20 * time.Second)
	c.AssertAssignmentCount(ctx, t, 1)
	c.Logf(t, "after 35s: assignment still present (agent is active) — remediator correctly skipped it")

	// Wait for Job to complete, then assignment should be cleaned up.
	c.WaitForJobStatus(ctx, t, agentName, "succeeded", 60*time.Second)
	c.WaitForAssignmentReleased(ctx, t, agentName, 90*time.Second)
	c.Logf(t, "TestStaleRemediation_ActiveKept passed")
}
