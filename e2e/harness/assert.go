//go:build e2e

// Package harness provides assertion helpers for e2e tests.
// All assert functions use t.Helper() and t.Fatal/t.Errorf to produce
// clean test failure messages with the correct file:line reference.
package harness

import (
	"context"
	"fmt"
	"testing"
)

// AssertQueueContains fails if the coordinator task queue does not contain all
// the specified issue numbers.
func (c *Cluster) AssertQueueContains(ctx context.Context, t *testing.T, issues ...int) {
	t.Helper()
	queue := c.GetTaskQueue(ctx, t)
	queueSet := make(map[int]bool, len(queue))
	for _, n := range queue {
		queueSet[n] = true
	}
	for _, want := range issues {
		if !queueSet[want] {
			t.Errorf("task queue missing issue #%d; queue=%v", want, queue)
		}
	}
}

// AssertQueueEmpty fails if the coordinator task queue is not empty.
func (c *Cluster) AssertQueueEmpty(ctx context.Context, t *testing.T) {
	t.Helper()
	queue := c.GetTaskQueue(ctx, t)
	if len(queue) != 0 {
		t.Errorf("expected empty task queue, got %v", queue)
	}
}

// AssertAssignmentCount fails if the number of active assignments is not exactly n.
func (c *Cluster) AssertAssignmentCount(ctx context.Context, t *testing.T, n int) {
	t.Helper()
	assignments := c.ListActiveAssignments(ctx, t)
	if len(assignments) != n {
		t.Errorf("expected %d active assignments, got %d: %v", n, len(assignments), assignments)
	}
}

// AssertNoAssignment fails if agentName has an active assignment.
func (c *Cluster) AssertNoAssignment(ctx context.Context, t *testing.T, agentName string) {
	t.Helper()
	assignments := c.ListActiveAssignments(ctx, t)
	if issue, ok := assignments[agentName]; ok {
		t.Errorf("expected no assignment for %s, but found issue #%d", agentName, issue)
	}
}

// AssertSpawnSlotsLE fails if spawnSlots > maxSlots (used to verify circuit breaker
// is not over-issuing slots even under concurrent activity).
func (c *Cluster) AssertSpawnSlotsLE(ctx context.Context, t *testing.T, maxSlots int) {
	t.Helper()
	slots := c.GetSpawnSlots(ctx, t)
	if slots > maxSlots {
		t.Errorf("spawnSlots=%d exceeds max %d (circuit breaker may be broken)", slots, maxSlots)
	}
}

// AssertReportCRPosted fails if no Report CR has been posted for the given agentName.
func (c *Cluster) AssertReportCRPosted(ctx context.Context, t *testing.T, agentName string) {
	t.Helper()
	reports := c.ListReportCRs(ctx, t)
	for _, r := range reports {
		spec, _ := r.Object["spec"].(map[string]interface{})
		if spec["agentRef"] == agentName {
			return
		}
	}
	t.Errorf("no Report CR found for agent %q (found %d total reports)", agentName, len(reports))
}

// AssertReportCRStatus fails if the Report CR for agentName does not have the expected status.
func (c *Cluster) AssertReportCRStatus(ctx context.Context, t *testing.T, agentName, wantStatus string) {
	t.Helper()
	reports := c.ListReportCRs(ctx, t)
	for _, r := range reports {
		spec, _ := r.Object["spec"].(map[string]interface{})
		if spec["agentRef"] == agentName {
			got, _ := spec["status"].(string)
			if got != wantStatus {
				t.Errorf("Report CR for %s: status=%q, want %q", agentName, got, wantStatus)
			}
			return
		}
	}
	t.Errorf("no Report CR found for agent %q", agentName)
}

// Logf is a convenience wrapper around t.Logf that prefixes with the cluster namespace.
func (c *Cluster) Logf(t *testing.T, format string, args ...interface{}) {
	t.Helper()
	t.Logf("[%s] %s", c.Namespace, fmt.Sprintf(format, args...))
}
