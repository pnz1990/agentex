//go:build e2e

package e2e

import (
	"fmt"
	"testing"
	"time"
)

// TestCircuitBreaker verifies that the coordinator's circuit breaker prevents
// spawn slots from going negative when the active job count reaches the limit.
//
// Scenario:
//  1. Set circuit breaker limit to 3 (via constitution patch).
//  2. Spawn 3 concurrent mock agents (each sleeping 8s).
//  3. Assert spawnSlots == 0 while all 3 are running.
//  4. Wait for all 3 to complete.
//  5. Assert spawnSlots recovers to >= 3 (coordinator reconciles).
func TestCircuitBreaker(t *testing.T) {
	c, ctx := newCluster(t)

	// Override the constitution circuit breaker limit to 3 for this test.
	c.PatchConstitutionField(ctx, t, "circuitBreakerLimit", "3")

	// Pre-set spawnSlots to 3 (matching the limit before any agents run).
	c.SetSpawnSlots(ctx, t, 3)

	const agentCount = 3
	const sleepSecs = 8

	for i := range agentCount {
		issueNum := 9100 + i
		agentName := c.Name(fmt.Sprintf("mock-cb-agent-%d", i))
		taskName := c.Name(fmt.Sprintf("task-cb-%d", i))

		c.CreateMockTaskCR(ctx, t, taskName, issueNum, fmt.Sprintf("circuit breaker test task %d", i))
		c.InjectActiveAssignment(ctx, t, agentName, issueNum)
		c.CreateMockAgentJob(ctx, t, agentName, taskName, "worker", sleepSecs, false)
		c.Logf(t, "spawned mock agent %s (issue #%d)", agentName, issueNum)
	}

	// Verify spawnSlots reaches 0 while 3 agents are running.
	// We poll until this holds — agents take ~8s so we have time.
	c.WaitReady(ctx, t, "spawn slots at 0", 15*time.Second, func() (bool, error) {
		slots := c.GetSpawnSlots(ctx, t)
		return slots == 0, nil
	})
	c.AssertSpawnSlotsLE(ctx, t, 0)
	c.Logf(t, "circuit breaker holding: spawnSlots=0 with %d active agents", agentCount)

	// Wait for all agents to complete.
	for i := range agentCount {
		agentName := c.Name(fmt.Sprintf("mock-cb-agent-%d", i))
		c.WaitForJobStatus(ctx, t, agentName, "succeeded", 60*time.Second)
		c.Logf(t, "agent %s completed", agentName)
	}

	// After completion, coordinator should reconcile spawn slots back up.
	// Allow up to 2 tick intervals (60s each = 120s) for detection.
	c.WaitReady(ctx, t, "spawn slots recovered", 150*time.Second, func() (bool, error) {
		slots := c.GetSpawnSlots(ctx, t)
		return slots >= 3, nil
	})
	c.Logf(t, "spawn slots recovered after all agents completed")
}
