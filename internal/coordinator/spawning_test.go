package coordinator

import (
	"context"
	"testing"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sfake "k8s.io/client-go/kubernetes/fake"

	"github.com/pnz1990/agentex/internal/config"
	k8sclient "github.com/pnz1990/agentex/internal/k8s"
	"github.com/pnz1990/agentex/internal/metrics"
)

func TestHandleCompletedAgents_SuccessReleasesAssignment(t *testing.T) {
	completionTime := metav1.Now()
	completedJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-done",
			Namespace: "agentex",
		},
		Status: batchv1.JobStatus{
			CompletionTime: &completionTime,
			Succeeded:      1,
		},
	}
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped":      "true",
			"spawnSlots":        "2",
			"activeAssignments": "agent-done:42,still-running:99",
			"taskQueue":         "",
		},
	}

	// Simulate a still-running job
	activeJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: "still-running", Namespace: "agentex"},
		Status:     batchv1.JobStatus{Active: 1},
	}

	fakeClientset := k8sfake.NewSimpleClientset(stateCM, completedJob, activeJob)
	logger := testLogger(t)
	client := k8sclient.NewClientFromInterfaces(fakeClientset, nil, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)

	reg := metrics.NewRegistry()
	m := RegisterMetrics(reg)

	coord := &Coordinator{
		client:        client,
		namespace:     "agentex",
		config:        cfg,
		stateManager:  NewStateManager(client, "agentex", logger),
		githubFetcher: &fakeGitHubFetcher{},
		logger:        logger,
		stopCh:        make(chan struct{}),
		metrics:       m,
		tracker:       newCompletionTracker(),
	}

	if err := coord.handleCompletedAgents(context.Background()); err != nil {
		t.Fatalf("handleCompletedAgents: %v", err)
	}

	cm, _ := fakeClientset.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	assignments := parseAssignments(cm.Data["activeAssignments"])

	// agent-done should be released
	if _, ok := assignments["agent-done"]; ok {
		t.Error("agent-done should have been released from assignments")
	}
	// still-running should remain
	if _, ok := assignments["still-running"]; !ok {
		t.Error("still-running should still be assigned")
	}

	// AgentsCompleted incremented
	if m.AgentsCompleted.GetValue() != 1 {
		t.Errorf("AgentsCompleted = %v, want 1", m.AgentsCompleted.GetValue())
	}
	if m.AgentsFailed.GetValue() != 0 {
		t.Errorf("AgentsFailed = %v, want 0 (agent succeeded)", m.AgentsFailed.GetValue())
	}
}

func TestHandleCompletedAgents_FailureRequeues(t *testing.T) {
	completionTime := metav1.Now()
	failedJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-fail",
			Namespace: "agentex",
		},
		Status: batchv1.JobStatus{
			CompletionTime: &completionTime,
			Failed:         1,
			Succeeded:      0, // failed — no successful pods
		},
	}
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped":      "true",
			"spawnSlots":        "2",
			"activeAssignments": "agent-fail:77",
			"taskQueue":         "100",
		},
	}

	fakeClientset := k8sfake.NewSimpleClientset(stateCM, failedJob)
	logger := testLogger(t)
	client := k8sclient.NewClientFromInterfaces(fakeClientset, nil, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)

	reg := metrics.NewRegistry()
	m := RegisterMetrics(reg)

	coord := &Coordinator{
		client:        client,
		namespace:     "agentex",
		config:        cfg,
		stateManager:  NewStateManager(client, "agentex", logger),
		githubFetcher: &fakeGitHubFetcher{},
		logger:        logger,
		stopCh:        make(chan struct{}),
		metrics:       m,
		tracker:       newCompletionTracker(),
	}

	if err := coord.handleCompletedAgents(context.Background()); err != nil {
		t.Fatalf("handleCompletedAgents: %v", err)
	}

	cm, _ := fakeClientset.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)

	// Agent should be released
	assignments := parseAssignments(cm.Data["activeAssignments"])
	if _, ok := assignments["agent-fail"]; ok {
		t.Error("agent-fail should have been released")
	}

	// Issue 77 should be re-queued
	queue := parseIntList(cm.Data["taskQueue"])
	found := false
	for _, n := range queue {
		if n == 77 {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("issue 77 should have been re-queued after failure, queue=%v", queue)
	}

	// AgentsFailed incremented
	if m.AgentsFailed.GetValue() != 1 {
		t.Errorf("AgentsFailed = %v, want 1", m.AgentsFailed.GetValue())
	}
}

func TestHandleCompletedAgents_Idempotent(t *testing.T) {
	completionTime := metav1.Now()
	completedJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agent-idempotent",
			Namespace: "agentex",
		},
		Status: batchv1.JobStatus{
			CompletionTime: &completionTime,
			Succeeded:      1,
		},
	}
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped":      "true",
			"spawnSlots":        "3",
			"activeAssignments": "agent-idempotent:42",
		},
	}

	fakeClientset := k8sfake.NewSimpleClientset(stateCM, completedJob)
	logger := testLogger(t)
	client := k8sclient.NewClientFromInterfaces(fakeClientset, nil, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)

	reg := metrics.NewRegistry()
	m := RegisterMetrics(reg)

	coord := &Coordinator{
		client:        client,
		namespace:     "agentex",
		config:        cfg,
		stateManager:  NewStateManager(client, "agentex", logger),
		githubFetcher: &fakeGitHubFetcher{},
		logger:        logger,
		stopCh:        make(chan struct{}),
		metrics:       m,
		tracker:       newCompletionTracker(),
	}

	// Call twice — should only process once
	if err := coord.handleCompletedAgents(context.Background()); err != nil {
		t.Fatalf("first call: %v", err)
	}
	if err := coord.handleCompletedAgents(context.Background()); err != nil {
		t.Fatalf("second call: %v", err)
	}

	// Should only have incremented once
	if m.AgentsCompleted.GetValue() != 1 {
		t.Errorf("AgentsCompleted = %v after 2 calls, want 1 (idempotent)", m.AgentsCompleted.GetValue())
	}
}

func TestHandleCompletedAgents_UnassignedJobIgnored(t *testing.T) {
	completionTime := metav1.Now()
	unassignedJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "orphan-job",
			Namespace: "agentex",
		},
		Status: batchv1.JobStatus{
			CompletionTime: &completionTime,
			Succeeded:      1,
		},
	}
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped":      "true",
			"spawnSlots":        "3",
			"activeAssignments": "", // no assignments
		},
	}

	fakeClientset := k8sfake.NewSimpleClientset(stateCM, unassignedJob)
	logger := testLogger(t)
	client := k8sclient.NewClientFromInterfaces(fakeClientset, nil, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)

	reg := metrics.NewRegistry()
	m := RegisterMetrics(reg)

	coord := &Coordinator{
		client:        client,
		namespace:     "agentex",
		config:        cfg,
		stateManager:  NewStateManager(client, "agentex", logger),
		githubFetcher: &fakeGitHubFetcher{},
		logger:        logger,
		stopCh:        make(chan struct{}),
		metrics:       m,
		tracker:       newCompletionTracker(),
	}

	if err := coord.handleCompletedAgents(context.Background()); err != nil {
		t.Fatalf("handleCompletedAgents: %v", err)
	}

	// No metrics should be incremented for unassigned jobs
	if m.AgentsCompleted.GetValue() != 0 {
		t.Errorf("AgentsCompleted = %v, want 0 for unassigned job", m.AgentsCompleted.GetValue())
	}
}

func TestIsJobCompleted(t *testing.T) {
	now := metav1.Now()
	tests := []struct {
		name string
		job  batchv1.Job
		want bool
	}{
		{
			name: "completed job",
			job:  batchv1.Job{Status: batchv1.JobStatus{CompletionTime: &now, Succeeded: 1}},
			want: true,
		},
		{
			name: "active job",
			job:  batchv1.Job{Status: batchv1.JobStatus{Active: 1}},
			want: false,
		},
		{
			name: "pending job",
			job:  batchv1.Job{Status: batchv1.JobStatus{}},
			want: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isJobCompleted(&tt.job); got != tt.want {
				t.Errorf("isJobCompleted() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestIsJobSucceeded(t *testing.T) {
	tests := []struct {
		name string
		job  batchv1.Job
		want bool
	}{
		{
			name: "succeeded",
			job:  batchv1.Job{Status: batchv1.JobStatus{Succeeded: 1}},
			want: true,
		},
		{
			name: "failed (no succeeded)",
			job:  batchv1.Job{Status: batchv1.JobStatus{Failed: 1, Succeeded: 0}},
			want: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isJobSucceeded(&tt.job); got != tt.want {
				t.Errorf("isJobSucceeded() = %v, want %v", got, tt.want)
			}
		})
	}
}

// Ensure time import is used.
var _ = time.Second
