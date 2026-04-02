//go:build e2e

package e2e

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// TestSwarmMemory verifies that 3 mock agents sharing FLIGHT_SWARM_NAME all
// appear in a single shared S3 swarm-memory object.
//
// Scenario:
//  1. Create 3 mock agents with the same FLIGHT_SWARM_NAME=swarm-e2e-<RunID>.
//  2. Each agent writes its swarm memory via the shared read-modify-write path
//     in s3_behaviors.go (writeSharedSwarmMemory).
//  3. Wait for all 3 Jobs to succeed.
//  4. Assert S3 object "swarm-memories/swarm-e2e-<RunID>.json" exists.
//  5. Assert all 3 agent names appear in the members array.
//  6. Assert keyDecisions is non-empty (at least one decision logged).
func TestSwarmMemory(t *testing.T) {
	c, ctx := newCluster(t)

	swarmName := c.Name("swarm-e2e")
	const agentCount = 3
	const issueBase = 9030

	// Prepare 3 agents sharing the same swarm name.
	type agentSpec struct {
		name        string
		taskCRName  string
		issueNumber int
	}
	agents := make([]agentSpec, agentCount)
	for i := 0; i < agentCount; i++ {
		agents[i] = agentSpec{
			name:        c.Name(fmt.Sprintf("swarm-agent-%d", i)),
			taskCRName:  c.Name(fmt.Sprintf("task-swarm-%d", i)),
			issueNumber: issueBase + i,
		}
	}

	// Create Task CRs and inject active assignments.
	for _, a := range agents {
		c.CreateMockTaskCR(ctx, t, a.taskCRName, a.issueNumber,
			fmt.Sprintf("Swarm memory test — agent %s", a.name))
		c.InjectActiveAssignment(ctx, t, a.name, a.issueNumber)
	}

	// Launch all 3 Jobs concurrently with the shared swarm name.
	for _, a := range agents {
		job := c.BuildFlightJob(a.name, a.taskCRName, "worker", 2, false, map[string]string{
			"FLIGHT_S3_ENABLED":   "true",
			"FLIGHT_SWARM_ENABLED": "true",
			"FLIGHT_SWARM_NAME":   swarmName,
		})
		c.CreateCustomJob(ctx, t, job)
		c.Logf(t, "created swarm agent job %s (swarm=%s)", a.name, swarmName)
	}

	// Wait for all 3 Jobs to succeed concurrently.
	var wg sync.WaitGroup
	for _, a := range agents {
		a := a // capture
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.WaitForJobStatus(ctx, t, a.name, "succeeded", 120*time.Second)
			c.Logf(t, "swarm agent job %s succeeded", a.name)
		}()
	}
	wg.Wait()

	// Wait for the shared swarm memory object to reflect all 3 members.
	// Each agent does a read-modify-write so membership builds up over time.
	c.WaitForS3SharedSwarmMemberCount(ctx, t, swarmName, agentCount, 60*time.Second)

	// Assert the shared swarm memory object.
	mem := c.GetS3SharedSwarmMemory(ctx, t, swarmName)

	if mem.SwarmName != swarmName {
		t.Errorf("swarm memory swarmName=%q, want %q", mem.SwarmName, swarmName)
	}

	// All 3 agent names must appear in members.
	memberSet := make(map[string]bool, len(mem.Members))
	for _, m := range mem.Members {
		memberSet[m] = true
	}
	for _, a := range agents {
		if !memberSet[a.name] {
			t.Errorf("agent %q not found in swarm members %v", a.name, mem.Members)
		}
	}

	// Decisions must be non-empty.
	if len(mem.Decisions) == 0 {
		t.Errorf("swarm memory keyDecisions is empty, expected at least one entry")
	}

	// Cleanup shared swarm S3 object.
	c.CleanupS3SharedSwarmMemory(ctx, t, swarmName)
	// Cleanup per-agent S3 objects.
	for _, a := range agents {
		c.CleanupE2ES3Prefix(ctx, t, a.name)
	}

	c.Logf(t, "TestSwarmMemory passed — %d agents in swarm %s", len(mem.Members), swarmName)
}
