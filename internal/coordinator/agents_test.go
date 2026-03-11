package coordinator

import (
	"context"
	"log/slog"
	"testing"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic/fake"
	k8sfake "k8s.io/client-go/kubernetes/fake"

	"github.com/pnz1990/agentex/internal/config"
	k8sclient "github.com/pnz1990/agentex/internal/k8s"
)

// newDynamicScheme returns a runtime.Scheme with the kro CRD GVRs registered
// for the fake dynamic client.
func newDynamicScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	s.AddKnownTypeWithName(
		schema.GroupVersionKind{Group: k8sclient.KroGroup, Version: k8sclient.KroVersion, Kind: "Agent"},
		&unstructured.Unstructured{},
	)
	s.AddKnownTypeWithName(
		schema.GroupVersionKind{Group: k8sclient.KroGroup, Version: k8sclient.KroVersion, Kind: "AgentList"},
		&unstructured.UnstructuredList{},
	)
	s.AddKnownTypeWithName(
		schema.GroupVersionKind{Group: k8sclient.KroGroup, Version: k8sclient.KroVersion, Kind: "Task"},
		&unstructured.Unstructured{},
	)
	s.AddKnownTypeWithName(
		schema.GroupVersionKind{Group: k8sclient.KroGroup, Version: k8sclient.KroVersion, Kind: "TaskList"},
		&unstructured.UnstructuredList{},
	)
	return s
}

// newTestCoordinatorWithDynamic creates a Coordinator with both fake typed and
// fake dynamic clients for testing agent lifecycle operations.
func newTestCoordinatorWithDynamic(t *testing.T, k8sObjects []runtime.Object, dynamicObjects ...runtime.Object) *Coordinator {
	t.Helper()
	logger := slog.Default()

	fakeClientset := k8sfake.NewSimpleClientset(k8sObjects...)
	fakeDynClient := fake.NewSimpleDynamicClient(newDynamicScheme(), dynamicObjects...)

	client := k8sclient.NewClientFromInterfaces(fakeClientset, fakeDynClient, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)

	return NewCoordinator(client, cfg, logger)
}

func TestIsKillSwitchActive(t *testing.T) {
	t.Run("active", func(t *testing.T) {
		ks := &corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{
				Name:      KillSwitchConfigMapName,
				Namespace: "agentex",
			},
			Data: map[string]string{
				"enabled": "true",
				"reason":  "Emergency stop",
			},
		}

		coord := newTestCoordinatorWithDynamic(t, []runtime.Object{
			defaultStateCM(), ks,
		})

		active, reason, err := coord.IsKillSwitchActive(context.Background())
		if err != nil {
			t.Fatalf("IsKillSwitchActive: %v", err)
		}
		if !active {
			t.Error("expected kill switch to be active")
		}
		if reason != "Emergency stop" {
			t.Errorf("reason = %q, want %q", reason, "Emergency stop")
		}
	})

	t.Run("inactive", func(t *testing.T) {
		ks := &corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{
				Name:      KillSwitchConfigMapName,
				Namespace: "agentex",
			},
			Data: map[string]string{
				"enabled": "false",
				"reason":  "",
			},
		}

		coord := newTestCoordinatorWithDynamic(t, []runtime.Object{
			defaultStateCM(), ks,
		})

		active, _, err := coord.IsKillSwitchActive(context.Background())
		if err != nil {
			t.Fatalf("IsKillSwitchActive: %v", err)
		}
		if active {
			t.Error("expected kill switch to be inactive")
		}
	})

	t.Run("missing configmap", func(t *testing.T) {
		coord := newTestCoordinatorWithDynamic(t, []runtime.Object{
			defaultStateCM(),
		})

		active, _, err := coord.IsKillSwitchActive(context.Background())
		if err != nil {
			t.Fatalf("IsKillSwitchActive: %v", err)
		}
		if active {
			t.Error("expected kill switch to be inactive when ConfigMap is missing")
		}
	})
}

func TestSpawnAgent_KillSwitchBlocks(t *testing.T) {
	ks := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      KillSwitchConfigMapName,
			Namespace: "agentex",
		},
		Data: map[string]string{
			"enabled": "true",
			"reason":  "Testing kill switch",
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
			"bootstrapped": "true",
			"spawnSlots":   "5",
		},
	}

	coord := newTestCoordinatorWithDynamic(t, []runtime.Object{stateCM, ks})

	err := coord.SpawnAgent(context.Background(), "worker", 42, "task-worker-1")
	if err == nil {
		t.Fatal("expected error when kill switch is active")
	}

	if got := err.Error(); got != "kill switch is active: Testing kill switch" {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestSpawnAgent_CircuitBreakerBlocks(t *testing.T) {
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped": "true",
			"spawnSlots":   "0",
		},
	}

	coord := newTestCoordinatorWithDynamic(t, []runtime.Object{stateCM})

	err := coord.SpawnAgent(context.Background(), "worker", 42, "task-worker-1")
	if err == nil {
		t.Fatal("expected error when spawn slots = 0")
	}

	expected := "circuit breaker: no spawn slots available (slots=0)"
	if got := err.Error(); got != expected {
		t.Errorf("error = %q, want %q", got, expected)
	}
}

func TestSpawnAgent_Success(t *testing.T) {
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped": "true",
			"spawnSlots":   "3",
		},
	}

	coord := newTestCoordinatorWithDynamic(t, []runtime.Object{stateCM})

	err := coord.SpawnAgent(context.Background(), "worker", 42, "task-worker-1")
	if err != nil {
		t.Fatalf("SpawnAgent: %v", err)
	}

	// Verify Task CR was created
	taskCR, err := coord.client.GetCR(context.Background(), "agentex", k8sclient.TaskGVR, "task-worker-1")
	if err != nil {
		t.Fatalf("getting Task CR: %v", err)
	}

	spec, ok := taskCR.Object["spec"].(map[string]interface{})
	if !ok {
		t.Fatal("Task CR missing spec")
	}
	if spec["assignee"] != "task-worker-1" {
		t.Errorf("Task assignee = %v, want %q", spec["assignee"], "task-worker-1")
	}
	if spec["issueNumber"] != "42" {
		t.Errorf("Task issueNumber = %v, want %q", spec["issueNumber"], "42")
	}

	// Verify Agent CR was created
	agentCR, err := coord.client.GetCR(context.Background(), "agentex", k8sclient.AgentGVR, "task-worker-1")
	if err != nil {
		t.Fatalf("getting Agent CR: %v", err)
	}

	agentSpec, ok := agentCR.Object["spec"].(map[string]interface{})
	if !ok {
		t.Fatal("Agent CR missing spec")
	}
	if agentSpec["role"] != "worker" {
		t.Errorf("Agent role = %v, want %q", agentSpec["role"], "worker")
	}
	if agentSpec["taskRef"] != "task-worker-1" {
		t.Errorf("Agent taskRef = %v, want %q", agentSpec["taskRef"], "task-worker-1")
	}

	// Verify spawn slots were decremented
	slotsStr, err := coord.stateManager.GetField(context.Background(), "spawnSlots")
	if err != nil {
		t.Fatalf("getting spawnSlots: %v", err)
	}
	if slotsStr != "2" {
		t.Errorf("spawnSlots = %q, want %q", slotsStr, "2")
	}
}

func TestCleanupCompletedAgents(t *testing.T) {
	completedTime := metav1.Now()

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
			"activeAssignments": "worker-active:100,worker-done:200",
			"activeAgents":      "worker-active:worker,worker-done:worker",
		},
	}

	activeJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "worker-active",
			Namespace: "agentex",
		},
		Status: batchv1.JobStatus{
			Active: 1,
		},
	}

	completedJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "worker-done",
			Namespace: "agentex",
		},
		Status: batchv1.JobStatus{
			CompletionTime: &completedTime,
			Succeeded:      1,
		},
	}

	coord := newTestCoordinatorWithDynamic(t, []runtime.Object{
		stateCM, activeJob, completedJob,
	})

	err := coord.CleanupCompletedAgents(context.Background())
	if err != nil {
		t.Fatalf("CleanupCompletedAgents: %v", err)
	}

	// Verify worker-done was removed from activeAssignments
	state, err := coord.stateManager.Load(context.Background())
	if err != nil {
		t.Fatalf("loading state: %v", err)
	}

	if _, ok := state.ActiveAssignments["worker-active"]; !ok {
		t.Error("worker-active should still be assigned")
	}
	if _, ok := state.ActiveAssignments["worker-done"]; ok {
		t.Error("worker-done should have been removed from assignments")
	}

	// Verify worker-done was removed from activeAgents
	for _, entry := range state.ActiveAgents {
		parts := splitAndTrim(entry, ":")
		if len(parts) > 0 && parts[0] == "worker-done" {
			t.Error("worker-done should have been removed from activeAgents")
		}
	}
}

func TestCleanupCompletedAgents_NoCompletedJobs(t *testing.T) {
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped":      "true",
			"spawnSlots":        "5",
			"activeAssignments": "worker-1:100",
			"activeAgents":      "worker-1:worker",
		},
	}

	activeJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "worker-1",
			Namespace: "agentex",
		},
		Status: batchv1.JobStatus{
			Active: 1,
		},
	}

	coord := newTestCoordinatorWithDynamic(t, []runtime.Object{
		stateCM, activeJob,
	})

	err := coord.CleanupCompletedAgents(context.Background())
	if err != nil {
		t.Fatalf("CleanupCompletedAgents: %v", err)
	}

	// Verify nothing was removed
	state, err := coord.stateManager.Load(context.Background())
	if err != nil {
		t.Fatalf("loading state: %v", err)
	}

	if len(state.ActiveAssignments) != 1 {
		t.Errorf("expected 1 active assignment, got %d", len(state.ActiveAssignments))
	}
}

func TestBuildTaskCR(t *testing.T) {
	cr := buildTaskCR("task-w1", "agent-w1", 42, "agentex")

	if cr.GetName() != "task-w1" {
		t.Errorf("name = %q, want %q", cr.GetName(), "task-w1")
	}
	if cr.GetNamespace() != "agentex" {
		t.Errorf("namespace = %q, want %q", cr.GetNamespace(), "agentex")
	}

	spec, ok := cr.Object["spec"].(map[string]interface{})
	if !ok {
		t.Fatal("missing spec")
	}
	if spec["title"] != "Work on issue #42" {
		t.Errorf("title = %v", spec["title"])
	}
	if spec["assignee"] != "agent-w1" {
		t.Errorf("assignee = %v", spec["assignee"])
	}
	if spec["effort"] != "M" {
		t.Errorf("effort = %v", spec["effort"])
	}
	if spec["issueNumber"] != "42" {
		t.Errorf("issueNumber = %v", spec["issueNumber"])
	}
}

func TestBuildAgentCR(t *testing.T) {
	cr := buildAgentCR("agent-w1", "worker", "task-w1", 42, "agentex")

	if cr.GetName() != "agent-w1" {
		t.Errorf("name = %q, want %q", cr.GetName(), "agent-w1")
	}
	if cr.GetNamespace() != "agentex" {
		t.Errorf("namespace = %q, want %q", cr.GetNamespace(), "agentex")
	}

	spec, ok := cr.Object["spec"].(map[string]interface{})
	if !ok {
		t.Fatal("missing spec")
	}
	if spec["name"] != "agent-w1" {
		t.Errorf("spec.name = %v", spec["name"])
	}
	if spec["role"] != "worker" {
		t.Errorf("spec.role = %v", spec["role"])
	}
	if spec["taskRef"] != "task-w1" {
		t.Errorf("spec.taskRef = %v", spec["taskRef"])
	}
	if spec["reason"] != "Assigned to issue #42" {
		t.Errorf("spec.reason = %v", spec["reason"])
	}
}

func TestCompletedJobNames(t *testing.T) {
	completedTime := metav1.Now()

	jobs := &batchv1.JobList{
		Items: []batchv1.Job{
			{
				ObjectMeta: metav1.ObjectMeta{Name: "active-1"},
				Status:     batchv1.JobStatus{Active: 1},
			},
			{
				ObjectMeta: metav1.ObjectMeta{Name: "done-1"},
				Status: batchv1.JobStatus{
					CompletionTime: &completedTime,
					Succeeded:      1,
				},
			},
			{
				ObjectMeta: metav1.ObjectMeta{Name: "done-2"},
				Status: batchv1.JobStatus{
					CompletionTime: &completedTime,
					Succeeded:      1,
				},
			},
		},
	}

	names := completedJobNames(jobs)
	if len(names) != 2 {
		t.Fatalf("expected 2 completed jobs, got %d: %v", len(names), names)
	}

	nameSet := make(map[string]bool)
	for _, n := range names {
		nameSet[n] = true
	}
	if !nameSet["done-1"] || !nameSet["done-2"] {
		t.Errorf("expected done-1 and done-2, got %v", names)
	}
	if nameSet["active-1"] {
		t.Error("active-1 should not be in completed list")
	}
}
