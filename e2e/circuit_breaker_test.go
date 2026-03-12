//go:build e2e

package e2e

import (
	"fmt"
	"testing"
	"time"
)

// TestCircuitBreaker verifies that the coordinator correctly reconciles
// spawn slots based on actual active job count.
//
// The coordinator reconciles spawnSlots every 4 ticks (60s with 15s heartbeat):
//
//	correctSlots = circuitBreakerLimit - activeJobs
//
// Scenario:
//  1. Set circuit breaker limit to 3.
//  2. Pre-set spawnSlots to 0 (simulating all slots consumed).
//  3. Spawn 3 agents (sleeping 20s each) so active job count = 3.
//  4. Wait for all 3 jobs to complete.
//  5. Wait for the coordinator to reconcile — spawnSlots should recover to 3.
func TestCircuitBreaker(t *testing.T) {
	c, ctx := newCluster(t)

	// Override the constitution circuit breaker limit to 3 for this test.
	c.PatchConstitutionField(ctx, t, "circuitBreakerLimit", "3")

	// Pre-set spawnSlots to 0 (simulating all slots consumed by prior agents).
	c.SetSpawnSlots(ctx, t, 0)

	const agentCount = 3
	const sleepSecs = 20 // must outlive one coordinator tick (15s heartbeat interval)

	for i := range agentCount {
		issueNum := 9100 + i
		agentName := c.Name(fmt.Sprintf("mock-cb-agent-%d", i))
		taskName := c.Name(fmt.Sprintf("task-cb-%d", i))

		c.CreateMockTaskCR(ctx, t, taskName, issueNum, fmt.Sprintf("circuit breaker test task %d", i))
		c.InjectActiveAssignment(ctx, t, agentName, issueNum)
		c.CreateMockAgentJob(ctx, t, agentName, taskName, "worker", sleepSecs, false)
		c.Logf(t, "spawned mock agent %s (issue #%d)", agentName, issueNum)
	}

	// Confirm slots are still 0 right after spawning — coordinator hasn't ticked yet.
	c.AssertSpawnSlotsLE(ctx, t, 0)
	c.Logf(t, "circuit breaker holding: spawnSlots=0 while agents are running")

	// Wait for all agents to complete.
	for i := range agentCount {
		agentName := c.Name(fmt.Sprintf("mock-cb-agent-%d", i))
		c.WaitForJobStatus(ctx, t, agentName, "succeeded", 60*time.Second)
		c.Logf(t, "agent %s completed", agentName)
	}

	// After all jobs complete, coordinator reconciles: correctSlots = limit - 0 = 3.
	// Allow up to 90s for the reconcile tick to fire (fires every 60s).
	c.WaitReady(ctx, t, "spawn slots recovered to 3", 90*time.Second, func() (bool, error) {
		slots := c.GetSpawnSlots(ctx, t)
		return slots >= 3, nil
	})
	c.Logf(t, "spawn slots recovered after all agents completed")
}
