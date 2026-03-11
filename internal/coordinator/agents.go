package coordinator

import (
	"context"
	"fmt"
	"strconv"

	batchv1 "k8s.io/api/batch/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	k8sclient "github.com/pnz1990/agentex/internal/k8s"
)

// KillSwitchConfigMapName is the name of the emergency kill switch ConfigMap.
const KillSwitchConfigMapName = "agentex-killswitch"

// SpawnAgent creates a new agent by:
//  1. Checking the kill switch
//  2. Checking the circuit breaker (spawn slots > 0)
//  3. Creating a Task CR with the assignment
//  4. Creating an Agent CR (which kro converts to a Job)
//  5. Decrementing spawn slots atomically
//
// Returns an error if the kill switch is active, no spawn slots are available,
// or any Kubernetes operation fails.
func (c *Coordinator) SpawnAgent(ctx context.Context, role string, issueNumber int, taskName string) error {
	// 1. Check kill switch
	active, reason, err := c.IsKillSwitchActive(ctx)
	if err != nil {
		return fmt.Errorf("checking kill switch: %w", err)
	}
	if active {
		return fmt.Errorf("kill switch is active: %s", reason)
	}

	// 2. Check circuit breaker (spawn slots)
	slotsStr, err := c.stateManager.GetField(ctx, "spawnSlots")
	if err != nil {
		return fmt.Errorf("reading spawn slots: %w", err)
	}
	slots := parseIntDefault(slotsStr, 0)
	if slots <= 0 {
		return fmt.Errorf("circuit breaker: no spawn slots available (slots=%d)", slots)
	}

	// Derive agent name from task name for consistency with bash convention.
	agentName := taskName

	// 3. Create Task CR
	taskCR := buildTaskCR(taskName, agentName, issueNumber, c.namespace)
	_, err = c.client.CreateCR(ctx, c.namespace, k8sclient.TaskGVR, taskCR)
	if err != nil {
		return fmt.Errorf("creating Task CR %s: %w", taskName, err)
	}

	c.logger.Info("created Task CR",
		"task", taskName,
		"issue", issueNumber,
		"role", role,
	)

	// 4. Create Agent CR
	agentCR := buildAgentCR(agentName, role, taskName, issueNumber, c.namespace)
	_, err = c.client.CreateCR(ctx, c.namespace, k8sclient.AgentGVR, agentCR)
	if err != nil {
		// Best-effort cleanup: delete the Task CR we just created.
		_ = c.client.DeleteCR(ctx, c.namespace, k8sclient.TaskGVR, taskName)
		return fmt.Errorf("creating Agent CR %s: %w", agentName, err)
	}

	c.logger.Info("created Agent CR",
		"agent", agentName,
		"role", role,
		"issue", issueNumber,
	)

	// 5. Decrement spawn slots atomically
	newSlots := slots - 1
	if newSlots < 0 {
		newSlots = 0
	}
	if err := c.stateManager.UpdateField(ctx, "spawnSlots", strconv.Itoa(newSlots)); err != nil {
		c.logger.Error("failed to decrement spawn slots after successful spawn",
			"agent", agentName,
			"error", err,
		)
		// Non-fatal: the agent was created successfully. Periodic reconciliation
		// will correct the spawn slot count.
	}

	return nil
}

// CleanupCompletedAgents finds Jobs that have completed and releases their
// assignments from the coordinator state. It lists all Jobs in the namespace,
// identifies completed ones, and removes their entries from activeAssignments
// and activeAgents.
func (c *Coordinator) CleanupCompletedAgents(ctx context.Context) error {
	jobs, err := c.client.ListJobs(ctx, c.namespace, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("listing jobs: %w", err)
	}

	completed := completedJobNames(jobs)
	if len(completed) == 0 {
		return nil
	}

	c.logger.Info("found completed agent jobs", "count", len(completed))

	// Remove completed agents from activeAssignments
	return c.stateManager.UpdateWithRetry(ctx, func(state *CoordinatorState) error {
		changed := false

		for _, jobName := range completed {
			if _, assigned := state.ActiveAssignments[jobName]; assigned {
				delete(state.ActiveAssignments, jobName)
				changed = true
				c.logger.Info("released assignment for completed agent",
					"agent", jobName,
				)
			}
		}

		if changed {
			// Also clean activeAgents list
			completedSet := make(map[string]struct{}, len(completed))
			for _, name := range completed {
				completedSet[name] = struct{}{}
			}

			var kept []string
			for _, entry := range state.ActiveAgents {
				parts := splitAndTrim(entry, ":")
				if len(parts) > 0 {
					if _, done := completedSet[parts[0]]; !done {
						kept = append(kept, entry)
					}
				}
			}
			state.ActiveAgents = kept
		}

		return nil
	})
}

// IsKillSwitchActive checks the agentex-killswitch ConfigMap. Returns true
// with the reason if the kill switch is enabled, false otherwise. If the
// ConfigMap does not exist, the kill switch is considered inactive.
func (c *Coordinator) IsKillSwitchActive(ctx context.Context) (bool, string, error) {
	cm, err := c.client.GetConfigMap(ctx, c.namespace, KillSwitchConfigMapName)
	if err != nil {
		if k8sclient.IsNotFound(err) {
			// No kill switch ConfigMap means it's not active.
			return false, "", nil
		}
		return false, "", fmt.Errorf("getting kill switch configmap: %w", err)
	}

	enabled := cm.Data["enabled"]
	reason := cm.Data["reason"]

	if enabled == "true" {
		return true, reason, nil
	}
	return false, "", nil
}

// buildTaskCR constructs an unstructured Task CR for kro.
func buildTaskCR(taskName, agentName string, issueNumber int, namespace string) *unstructured.Unstructured {
	return &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8sclient.KroGroup + "/" + k8sclient.KroVersion,
			"kind":       "Task",
			"metadata": map[string]interface{}{
				"name":      taskName,
				"namespace": namespace,
				"labels": map[string]interface{}{
					"agentex/component": "task",
					"agentex/issue":     strconv.Itoa(issueNumber),
				},
			},
			"spec": map[string]interface{}{
				"title":       fmt.Sprintf("Work on issue #%d", issueNumber),
				"description": fmt.Sprintf("Implement changes for GitHub issue #%d", issueNumber),
				"assignee":    agentName,
				"effort":      "M",
				"issueNumber": strconv.Itoa(issueNumber),
			},
		},
	}
}

// buildAgentCR constructs an unstructured Agent CR for kro.
func buildAgentCR(agentName, role, taskName string, issueNumber int, namespace string) *unstructured.Unstructured {
	return &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8sclient.KroGroup + "/" + k8sclient.KroVersion,
			"kind":       "Agent",
			"metadata": map[string]interface{}{
				"name":      agentName,
				"namespace": namespace,
				"labels": map[string]interface{}{
					"agentex/component": "agent",
					"agentex/role":      role,
				},
			},
			"spec": map[string]interface{}{
				"name":    agentName,
				"role":    role,
				"taskRef": taskName,
				"reason":  fmt.Sprintf("Assigned to issue #%d", issueNumber),
			},
		},
	}
}

// completedJobNames returns the names of Jobs that have a CompletionTime set
// (i.e., they have finished running).
func completedJobNames(jobs *batchv1.JobList) []string {
	var names []string
	for i := range jobs.Items {
		if jobs.Items[i].Status.CompletionTime != nil {
			names = append(names, jobs.Items[i].Name)
		}
	}
	return names
}
