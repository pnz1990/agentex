package coordinator

import (
	"context"
	"fmt"
	"strconv"

	batchv1 "k8s.io/api/batch/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// completionTracker tracks which Jobs have already been processed so we don't
// double-release assignments across ticks. Stored in-memory; resets on
// coordinator restart (acceptable — coordinator re-detects on next scan).
type completionTracker struct {
	processed map[string]bool
}

func newCompletionTracker() *completionTracker {
	return &completionTracker{processed: make(map[string]bool)}
}

func (t *completionTracker) markProcessed(jobName string)         { t.processed[jobName] = true }
func (t *completionTracker) alreadyProcessed(jobName string) bool { return t.processed[jobName] }

// handleCompletedAgents scans all Jobs for newly completed agents (succeeded or failed),
// releases their assignments, re-queues their issues on failure, and optionally
// triggers an immediate dispatch cycle.
//
// Phase 1: runs alongside agent self-perpetuation (backward compatible).
// Phase 2 (coordinator-controlled spawning): enabled when coordinatorSpawnsEnabled=true.
// Set via coordinator-state ConfigMap field "coordinatorSpawns=true".
func (c *Coordinator) handleCompletedAgents(ctx context.Context) error {
	jobs, err := c.client.ListJobs(ctx, c.namespace, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("listing jobs for completion detection: %w", err)
	}

	state, err := c.stateManager.Load(ctx)
	if err != nil {
		return fmt.Errorf("loading state for completion handling: %w", err)
	}

	for i := range jobs.Items {
		job := &jobs.Items[i]
		if !isJobCompleted(job) {
			continue
		}
		if c.tracker.alreadyProcessed(job.Name) {
			continue
		}

		c.tracker.markProcessed(job.Name)

		succeeded := isJobSucceeded(job)
		issueNumber, wasAssigned := state.ActiveAssignments[job.Name]

		if wasAssigned {
			c.logger.Info("detected completed agent",
				"agent", job.Name,
				"issue", issueNumber,
				"succeeded", succeeded,
			)

			// Release the assignment (re-read state inside ReleaseAssignment for safety)
			if err := c.ReleaseAssignment(ctx, job.Name, issueNumber); err != nil {
				c.logger.Error("failed to release assignment for completed agent",
					"agent", job.Name, "error", err,
				)
				// Continue — don't block other completions
			}

			// If the agent failed, re-queue the issue
			if !succeeded {
				c.logger.Warn("agent failed — re-queuing issue for retry",
					"agent", job.Name, "issue", issueNumber,
				)
				if err := c.RequeueIssue(ctx, issueNumber); err != nil {
					c.logger.Error("failed to re-queue issue after agent failure",
						"issue", issueNumber, "error", err,
					)
				}
			}

			// Update lifecycle metrics
			if c.metrics != nil {
				if succeeded {
					c.metrics.AgentsCompleted.Inc()
				} else {
					c.metrics.AgentsFailed.Inc()
				}
			}
		}

		// Phase 2: coordinator-spawns mode — immediately dispatch to fill the freed slot.
		if c.coordinatorSpawnsEnabled && wasAssigned {
			c.logger.Debug("coordinator-spawns: immediate post-completion dispatch",
				"agent", job.Name,
			)
			if err := c.dispatchNextTask(ctx); err != nil {
				c.logger.Error("immediate post-completion dispatch failed", "error", err)
			}
		}
	}

	return nil
}

// refreshCoordinatorSpawnsFlag reads the "coordinatorSpawns" field from the
// coordinator-state ConfigMap and caches it on the coordinator struct.
// This is called once at startup and can be refreshed via reconciliation.
func (c *Coordinator) refreshCoordinatorSpawnsFlag(ctx context.Context) {
	val, err := c.stateManager.GetField(ctx, "coordinatorSpawns")
	if err != nil {
		return
	}
	c.coordinatorSpawnsEnabled = (val == "true")
	if c.coordinatorSpawnsEnabled {
		c.logger.Info("coordinator-spawns mode enabled")
	}
}

// isJobCompleted returns true if the Job has a completion time set.
// Completed includes both succeeded and failed Jobs.
func isJobCompleted(job *batchv1.Job) bool {
	return job.Status.CompletionTime != nil
}

// isJobSucceeded returns true if the Job completed with at least one successful pod.
func isJobSucceeded(job *batchv1.Job) bool {
	return job.Status.Succeeded > 0
}

// issueFromJobLabel extracts the issue number from the Job's agentex/issue label.
func issueFromJobLabel(job *batchv1.Job) (int, bool) {
	if job.Labels == nil {
		return 0, false
	}
	label, ok := job.Labels["agentex/issue"]
	if !ok {
		return 0, false
	}
	n, err := strconv.Atoi(label)
	if err != nil {
		return 0, false
	}
	return n, true
}
