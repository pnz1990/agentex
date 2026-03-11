package coordinator

import (
	"context"
	"fmt"

	"github.com/pnz1990/agentex/internal/health"
)

// maxRemediationsPerTick is the maximum number of remediation actions taken in
// a single coordinator tick. This prevents a cascading remediation storm where
// a large number of stale assignments are all remediated simultaneously,
// potentially overloading the cluster.
const maxRemediationsPerTick = 3

// Remediator runs health checks and takes automated recovery actions.
// It is a thin layer between the health.Monitor results and coordinator methods.
type Remediator struct {
	coord *Coordinator
}

// newRemediator creates a Remediator for the given coordinator.
func newRemediator(c *Coordinator) *Remediator {
	return &Remediator{coord: c}
}

// RunRemediation runs health checks and automatically fixes any detected issues.
// It respects the per-tick rate limit and only acts when the kill switch is off.
// Returns the number of remediations performed.
func (r *Remediator) RunRemediation(ctx context.Context, monitor *health.Monitor) (int, error) {
	// Never remediate when kill switch is active
	active, reason, err := r.coord.IsKillSwitchActive(ctx)
	if err != nil {
		return 0, fmt.Errorf("checking kill switch before remediation: %w", err)
	}
	if active {
		r.coord.logger.Debug("remediation skipped: kill switch active", "reason", reason)
		return 0, nil
	}

	report := monitor.RunOnce(ctx)

	if report.Overall == health.StatusHealthy {
		return 0, nil
	}

	r.coord.logger.Info("health check detected issues, running remediation",
		"overall", report.Overall,
	)

	count := 0
	for _, check := range report.Checks {
		if count >= maxRemediationsPerTick {
			r.coord.logger.Warn("remediation rate limit reached", "limit", maxRemediationsPerTick)
			break
		}
		if check.Status == health.StatusHealthy {
			continue
		}

		n, err := r.remediateCheck(ctx, check)
		if err != nil {
			r.coord.logger.Error("remediation failed",
				"check", check.Name,
				"error", err,
			)
			// Continue with other checks — don't abort on single failure
			continue
		}
		count += n
	}

	return count, nil
}

// remediateCheck handles a single unhealthy check result and returns the number
// of remediation actions taken.
func (r *Remediator) remediateCheck(ctx context.Context, check health.Check) (int, error) {
	switch check.Name {
	case "stale-assignments":
		return r.remediateStaleAssignments(ctx)
	case "spawn-slot-consistency":
		if check.Status == health.StatusCritical {
			return r.remediateSpawnSlots(ctx)
		}
	case "coordinator-heartbeat":
		// Nothing the coordinator can do about its own dead heartbeat — it would
		// only fire if this check runs on a secondary coordinator instance.
		r.coord.logger.Warn("coordinator heartbeat check failed — possible split brain",
			"message", check.Message,
		)
	}
	return 0, nil
}

// remediateStaleAssignments finds assignments whose Jobs are gone and releases them.
// Returns the number of assignments released.
func (r *Remediator) remediateStaleAssignments(ctx context.Context) (int, error) {
	state, err := r.coord.stateManager.Load(ctx)
	if err != nil {
		return 0, fmt.Errorf("loading state for stale assignment remediation: %w", err)
	}

	count := 0
	for agent, issue := range state.ActiveAssignments {
		active, err := r.coord.isJobActive(ctx, agent)
		if err != nil {
			r.coord.logger.Warn("error checking job during remediation, skipping",
				"agent", agent, "error", err,
			)
			continue
		}
		if !active {
			r.coord.logger.Info("remediating stale assignment",
				"agent", agent, "issue", issue,
			)
			if err := r.coord.ReleaseAssignment(ctx, agent, issue); err != nil {
				r.coord.logger.Error("failed to release stale assignment",
					"agent", agent, "issue", issue, "error", err,
				)
				continue
			}
			if err := r.coord.RequeueIssue(ctx, issue); err != nil {
				r.coord.logger.Error("failed to re-queue issue after stale assignment release",
					"issue", issue, "error", err,
				)
			}
			count++

			// Emit remediation metric
			if r.coord.metrics != nil {
				r.coord.metrics.HealthCheckErrors.Inc("action", "release_stale_assignment")
			}
		}
	}

	return count, nil
}

// remediateSpawnSlots resets negative spawn slots to the correct value.
func (r *Remediator) remediateSpawnSlots(ctx context.Context) (int, error) {
	r.coord.logger.Warn("remediating spawn slot inconsistency via full reconciliation")
	if err := r.coord.reconcileSpawnSlots(ctx); err != nil {
		return 0, fmt.Errorf("spawn slot reconciliation during remediation: %w", err)
	}
	if r.coord.metrics != nil {
		r.coord.metrics.HealthCheckErrors.Inc("action", "reset_spawn_slots")
	}
	return 1, nil
}

// KillStuckAgent deletes the Job for the given agent (if it exists) and
// releases its assignment from the coordinator state. It is idempotent — safe
// to call even if the Job has already been deleted or never existed.
func (c *Coordinator) KillStuckAgent(ctx context.Context, agentName string) error {
	// Delete the Job (if it still exists)
	if err := c.client.DeleteJob(ctx, c.namespace, agentName); err != nil {
		c.logger.Warn("could not delete stuck agent Job (may already be gone)",
			"agent", agentName, "error", err,
		)
		// Non-fatal — proceed to release the assignment
	}

	// Read state to find the issue number for this agent
	state, err := c.stateManager.Load(ctx)
	if err != nil {
		return fmt.Errorf("loading state to find assignment for %s: %w", agentName, err)
	}

	issueNumber, assigned := state.ActiveAssignments[agentName]
	if assigned {
		if err := c.ReleaseAssignment(ctx, agentName, issueNumber); err != nil {
			return fmt.Errorf("releasing assignment for killed agent %s: %w", agentName, err)
		}
	}

	c.logger.Info("killed stuck agent",
		"agent", agentName,
		"issue", issueNumber,
		"wasAssigned", assigned,
	)

	if c.metrics != nil {
		c.metrics.AgentsFailed.Inc()
	}

	return nil
}

// ReleaseAssignment removes an agent's assignment from activeAssignments and
// increments spawnSlots by 1. It is idempotent — if the agent is not in
// activeAssignments, it is a no-op (no error).
func (c *Coordinator) ReleaseAssignment(ctx context.Context, agentName string, issueNumber int) error {
	return c.stateManager.UpdateWithRetry(ctx, func(state *CoordinatorState) error {
		if _, exists := state.ActiveAssignments[agentName]; !exists {
			// Already released — idempotent, no error.
			return nil
		}
		delete(state.ActiveAssignments, agentName)
		state.SpawnSlots++

		c.logger.Info("released assignment",
			"agent", agentName,
			"issue", issueNumber,
			"newSpawnSlots", state.SpawnSlots,
		)
		return nil
	})
}

// RequeueIssue adds an issue back to the front of the taskQueue if it is not
// already present. This is called after a failed or cancelled assignment so
// the issue gets picked up on the next dispatch cycle.
func (c *Coordinator) RequeueIssue(ctx context.Context, issueNumber int) error {
	return c.stateManager.UpdateWithRetry(ctx, func(state *CoordinatorState) error {
		// Check if already in queue
		for _, n := range state.TaskQueue {
			if n == issueNumber {
				return nil // already queued — idempotent
			}
		}
		// Prepend to give it priority over fresh issues
		state.TaskQueue = append([]int{issueNumber}, state.TaskQueue...)
		c.logger.Info("re-queued issue after assignment release",
			"issue", issueNumber,
			"queueSize", len(state.TaskQueue),
		)
		return nil
	})
}

// runRemediation is called periodically from the coordinator tick loop.
// It respects autoRemediate flag (always true for now) and the per-tick limit.
func (c *Coordinator) runRemediation(ctx context.Context) error {
	if c.healthMonitor == nil {
		return nil
	}
	rem := newRemediator(c)
	n, err := rem.RunRemediation(ctx, c.healthMonitor)
	if err != nil {
		return err
	}
	if n > 0 {
		c.logger.Info("remediation cycle completed", "actionsCount", n)
		if c.metrics != nil {
			c.metrics.HealthCheckTotal.Inc()
			c.metrics.RemediationsTotal.Add(float64(n))
		}
	}
	return nil
}
