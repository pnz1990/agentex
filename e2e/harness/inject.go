//go:build e2e

package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/pnz1990/agentex/internal/k8s"
)

// InjectTaskQueue writes a list of issue numbers into the coordinator-state taskQueue.
func (c *Cluster) InjectTaskQueue(ctx context.Context, t *testing.T, issues []int) {
	t.Helper()
	parts := make([]string, len(issues))
	for i, n := range issues {
		parts[i] = strconv.Itoa(n)
	}
	val := strings.Join(parts, ",")
	if err := c.patchStateField(ctx, "taskQueue", val); err != nil {
		t.Fatalf("inject taskQueue: %v", err)
	}
}

// InjectActiveAssignment writes a single active assignment into coordinator-state.
// This simulates an agent that was dispatched but whose Job is now gone (stale).
func (c *Cluster) InjectActiveAssignment(ctx context.Context, t *testing.T, agentName string, issueNumber int) {
	t.Helper()
	current, err := c.ReadCoordinatorState(ctx)
	if err != nil {
		t.Fatalf("inject assignment: read state: %v", err)
	}
	existing := current["activeAssignments"]
	entry := fmt.Sprintf("%s:%d", agentName, issueNumber)
	var next string
	if existing == "" {
		next = entry
	} else {
		next = existing + "," + entry
	}
	if err := c.patchStateField(ctx, "activeAssignments", next); err != nil {
		t.Fatalf("inject assignment: patch: %v", err)
	}
}

// SetSpawnSlots directly sets the spawnSlots field in coordinator-state.
func (c *Cluster) SetSpawnSlots(ctx context.Context, t *testing.T, slots int) {
	t.Helper()
	if err := c.patchStateField(ctx, "spawnSlots", strconv.Itoa(slots)); err != nil {
		t.Fatalf("set spawnSlots: %v", err)
	}
}

// CreateMockTaskCR creates a Task CR (kro.run/v1alpha1) for a mock agent.
// Uses the actual RGD schema: githubIssue (integer), title, description, effort, role.
func (c *Cluster) CreateMockTaskCR(ctx context.Context, t *testing.T, name string, issueNumber int, title string) {
	t.Helper()
	obj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8s.KroGroup + "/" + k8s.KroVersion,
			"kind":       "Task",
			"metadata": map[string]interface{}{
				"name":      name,
				"namespace": c.Namespace,
			},
			"spec": map[string]interface{}{
				"githubIssue": int64(issueNumber),
				"title":       title,
				"description": "e2e flight test task",
				"effort":      "S",
				"role":        "worker",
				"priority":    int64(5),
			},
		},
	}
	_, err := c.Client.CreateCR(ctx, c.Namespace, k8s.TaskGVR, obj)
	if err != nil {
		t.Fatalf("create task CR %s: %v", name, err)
	}
}

// CreateMockAgentJob creates a Kubernetes Job that runs the agent in flight test mode.
// The Job runs the agentex-agent binary with AGENTEX_FLIGHT_TEST=true.
func (c *Cluster) CreateMockAgentJob(ctx context.Context, t *testing.T, agentName, taskCRName, role string, sleepSeconds int, fail bool) {
	t.Helper()

	image := envOrDefault("FLIGHT_TEST_IMAGE", "agentex/runner:latest")
	failStr := "false"
	if fail {
		failStr = "true"
	}

	job := buildMockAgentJob(agentName, taskCRName, role, c.Namespace, image, sleepSeconds, failStr)
	_, err := c.Client.Clientset.BatchV1().Jobs(c.Namespace).Create(ctx, job, metav1.CreateOptions{})
	if err != nil {
		t.Fatalf("create mock agent job %s: %v", agentName, err)
	}
}

// GetJobStatus returns "active", "succeeded", "failed", or "unknown".
func (c *Cluster) GetJobStatus(ctx context.Context, jobName string) string {
	job, err := c.Client.GetJob(ctx, c.Namespace, jobName)
	if err != nil {
		return "unknown"
	}
	if job.Status.Succeeded > 0 {
		return "succeeded"
	}
	if job.Status.Failed > 0 {
		return "failed"
	}
	if job.Status.Active > 0 {
		return "active"
	}
	return "pending"
}

// ListActiveAssignments returns the current activeAssignments from coordinator-state.
func (c *Cluster) ListActiveAssignments(ctx context.Context, t *testing.T) map[string]int {
	t.Helper()
	data, err := c.ReadCoordinatorState(ctx)
	if err != nil {
		t.Fatalf("list active assignments: %v", err)
	}
	return parseAssignments(data["activeAssignments"])
}

// GetSpawnSlots returns the current spawnSlots value from coordinator-state.
func (c *Cluster) GetSpawnSlots(ctx context.Context, t *testing.T) int {
	t.Helper()
	data, err := c.ReadCoordinatorState(ctx)
	if err != nil {
		t.Fatalf("get spawn slots: %v", err)
	}
	n, _ := strconv.Atoi(data["spawnSlots"])
	return n
}

// GetTaskQueue returns the current taskQueue from coordinator-state.
func (c *Cluster) GetTaskQueue(ctx context.Context, t *testing.T) []int {
	t.Helper()
	data, err := c.ReadCoordinatorState(ctx)
	if err != nil {
		t.Fatalf("get task queue: %v", err)
	}
	return parseIntList(data["taskQueue"])
}

// ListReportCRs returns all Report CRs in the namespace.
func (c *Cluster) ListReportCRs(ctx context.Context, t *testing.T) []unstructured.Unstructured {
	t.Helper()
	list, err := c.Client.ListCRs(ctx, c.Namespace, k8s.ReportGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("list report CRs: %v", err)
	}
	return list.Items
}

// WaitForJobStatus polls until the named Job reaches the expected status.
func (c *Cluster) WaitForJobStatus(ctx context.Context, t *testing.T, jobName, wantStatus string, timeout time.Duration) {
	t.Helper()
	c.WaitReady(ctx, t, fmt.Sprintf("job %s status=%s", jobName, wantStatus), timeout, func() (bool, error) {
		got := c.GetJobStatus(ctx, jobName)
		return got == wantStatus, nil
	})
}

// WaitForAssignmentReleased polls until agentName is no longer in activeAssignments.
func (c *Cluster) WaitForAssignmentReleased(ctx context.Context, t *testing.T, agentName string, timeout time.Duration) {
	t.Helper()
	c.WaitReady(ctx, t, fmt.Sprintf("assignment released for %s", agentName), timeout, func() (bool, error) {
		assignments := c.ListActiveAssignments(ctx, t)
		_, stillActive := assignments[agentName]
		return !stillActive, nil
	})
}

// WaitForQueueDrained polls until taskQueue is empty.
func (c *Cluster) WaitForQueueDrained(ctx context.Context, t *testing.T, timeout time.Duration) {
	t.Helper()
	c.WaitReady(ctx, t, "task queue drained", timeout, func() (bool, error) {
		queue := c.GetTaskQueue(ctx, t)
		return len(queue) == 0, nil
	})
}

// WaitForReportCR polls until at least minCount Report CRs exist in the namespace.
func (c *Cluster) WaitForReportCR(ctx context.Context, t *testing.T, minCount int, timeout time.Duration) {
	t.Helper()
	c.WaitReady(ctx, t, fmt.Sprintf("at least %d report CRs", minCount), timeout, func() (bool, error) {
		reports := c.ListReportCRs(ctx, t)
		return len(reports) >= minCount, nil
	})
}

// PatchConstitutionField patches a single key in the agentex-constitution ConfigMap.
func (c *Cluster) PatchConstitutionField(ctx context.Context, t *testing.T, key, value string) {
	t.Helper()
	patch := map[string]interface{}{
		"data": map[string]string{
			key: value,
		},
	}
	patchBytes, err := json.Marshal(patch)
	if err != nil {
		t.Fatalf("patch constitution %s: marshal: %v", key, err)
	}
	_, err = c.Client.PatchConfigMap(ctx, c.Namespace, ConstitutionMap, patchBytes)
	if err != nil {
		t.Fatalf("patch constitution %s: %v", key, err)
	}
}

// patchStateField patches a single key in the coordinator-state ConfigMap.
func (c *Cluster) patchStateField(ctx context.Context, field, value string) error {
	patch := map[string]interface{}{
		"data": map[string]string{
			field: value,
		},
	}
	patchBytes, err := json.Marshal(patch)
	if err != nil {
		return fmt.Errorf("marshal patch: %w", err)
	}
	_, err = c.Client.PatchConfigMap(ctx, c.Namespace, CoordinatorStateMap, patchBytes)
	return err
}

// parseAssignments parses "agent1:123,agent2:456" into a map.
func parseAssignments(s string) map[string]int {
	result := make(map[string]int)
	if s == "" {
		return result
	}
	for _, pair := range strings.Split(s, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		parts := strings.SplitN(pair, ":", 2)
		if len(parts) != 2 {
			continue
		}
		agent := strings.TrimSpace(parts[0])
		issue, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || agent == "" {
			continue
		}
		result[agent] = issue
	}
	return result
}

// parseIntList splits a comma-separated string of ints.
func parseIntList(s string) []int {
	if s == "" {
		return nil
	}
	var result []int
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if n, err := strconv.Atoi(part); err == nil {
			result = append(result, n)
		}
	}
	return result
}
