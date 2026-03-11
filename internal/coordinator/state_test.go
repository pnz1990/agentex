package coordinator

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"

	k8sclient "github.com/pnz1990/agentex/internal/k8s"
)

func newTestStateManager(t *testing.T, cm *corev1.ConfigMap) (*StateManager, *fake.Clientset) {
	t.Helper()
	fakeClient := fake.NewSimpleClientset(cm)
	logger := slog.Default()
	client := k8sclient.NewClientFromInterfaces(fakeClient, nil, logger)
	sm := NewStateManager(client, "agentex", logger)
	return sm, fakeClient
}

func makeStateCM(data map[string]string) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1000",
			Labels: map[string]string{
				"agentex/component": "coordinator",
			},
		},
		Data: data,
	}
}

func TestStateLoad(t *testing.T) {
	cm := makeStateCM(map[string]string{
		"taskQueue":         "100,200,300",
		"activeAssignments": "worker-1:100,worker-2:200",
		"spawnSlots":        "5",
		"visionQueue":       "feature:test:ts:agent;42",
		"lastHeartbeat":     "2025-06-15T10:30:00Z",
		"activeAgents":      "worker-1:worker,planner-1:planner",
		"decisionLog":       "2025-06-15T10:00:00Z task_assigned reason=vision_priority",
		"enactedDecisions":  "2025-06-15T09:00:00Z enacted_topic_circuit-breaker approvals=3",
		"bootstrapped":      "true",
	})

	sm, _ := newTestStateManager(t, cm)
	state, err := sm.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// TaskQueue
	if len(state.TaskQueue) != 3 {
		t.Errorf("TaskQueue length = %d, want 3", len(state.TaskQueue))
	}
	if state.TaskQueue[0] != 100 || state.TaskQueue[1] != 200 || state.TaskQueue[2] != 300 {
		t.Errorf("TaskQueue = %v, want [100 200 300]", state.TaskQueue)
	}

	// ActiveAssignments
	if len(state.ActiveAssignments) != 2 {
		t.Errorf("ActiveAssignments length = %d, want 2", len(state.ActiveAssignments))
	}
	if state.ActiveAssignments["worker-1"] != 100 {
		t.Errorf("ActiveAssignments[worker-1] = %d, want 100", state.ActiveAssignments["worker-1"])
	}
	if state.ActiveAssignments["worker-2"] != 200 {
		t.Errorf("ActiveAssignments[worker-2] = %d, want 200", state.ActiveAssignments["worker-2"])
	}

	// SpawnSlots
	if state.SpawnSlots != 5 {
		t.Errorf("SpawnSlots = %d, want 5", state.SpawnSlots)
	}

	// VisionQueue
	if len(state.VisionQueue) != 2 {
		t.Errorf("VisionQueue length = %d, want 2", len(state.VisionQueue))
	}

	// LastHeartbeat
	expected := time.Date(2025, 6, 15, 10, 30, 0, 0, time.UTC)
	if !state.LastHeartbeat.Equal(expected) {
		t.Errorf("LastHeartbeat = %v, want %v", state.LastHeartbeat, expected)
	}

	// ActiveAgents
	if len(state.ActiveAgents) != 2 {
		t.Errorf("ActiveAgents length = %d, want 2", len(state.ActiveAgents))
	}

	// ResourceVersion
	if state.ResourceVersion != "1000" {
		t.Errorf("ResourceVersion = %q, want %q", state.ResourceVersion, "1000")
	}
}

func TestStateLoadEmpty(t *testing.T) {
	cm := makeStateCM(map[string]string{
		"bootstrapped": "true",
	})

	sm, _ := newTestStateManager(t, cm)
	state, err := sm.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if len(state.TaskQueue) != 0 {
		t.Errorf("TaskQueue = %v, want empty", state.TaskQueue)
	}
	if len(state.ActiveAssignments) != 0 {
		t.Errorf("ActiveAssignments = %v, want empty", state.ActiveAssignments)
	}
	if state.SpawnSlots != 0 {
		t.Errorf("SpawnSlots = %d, want 0", state.SpawnSlots)
	}
}

func TestStateSave(t *testing.T) {
	cm := makeStateCM(map[string]string{"bootstrapped": "true"})
	sm, fakeClient := newTestStateManager(t, cm)

	state := &CoordinatorState{
		TaskQueue:         []int{42, 99, 123},
		ActiveAssignments: map[string]int{"agent-a": 42, "agent-b": 99},
		SpawnSlots:        3,
		VisionQueue:       []string{"feature:test:ts:agent"},
		LastHeartbeat:     time.Date(2025, 6, 15, 12, 0, 0, 0, time.UTC),
		ActiveAgents:      []string{"agent-a:worker", "agent-b:planner"},
		DecisionLog:       "some log entry",
		EnactedDecisions:  "some enacted decision",
		ResourceVersion:   "1000",
	}

	err := sm.Save(context.Background(), state)
	if err != nil {
		t.Fatalf("Save: %v", err)
	}

	// Verify the saved ConfigMap
	saved, err := fakeClient.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("Getting saved CM: %v", err)
	}

	if saved.Data["taskQueue"] != "42,99,123" {
		t.Errorf("taskQueue = %q, want %q", saved.Data["taskQueue"], "42,99,123")
	}
	if saved.Data["spawnSlots"] != "3" {
		t.Errorf("spawnSlots = %q, want %q", saved.Data["spawnSlots"], "3")
	}
	if saved.Data["lastHeartbeat"] != "2025-06-15T12:00:00Z" {
		t.Errorf("lastHeartbeat = %q", saved.Data["lastHeartbeat"])
	}
	if saved.Data["bootstrapped"] != "true" {
		t.Errorf("bootstrapped = %q, want %q", saved.Data["bootstrapped"], "true")
	}

	// ActiveAssignments: order is non-deterministic in maps, just check both entries exist
	aa := saved.Data["activeAssignments"]
	if !strings.Contains(aa, "agent-a:42") || !strings.Contains(aa, "agent-b:99") {
		t.Errorf("activeAssignments = %q, want agent-a:42 and agent-b:99", aa)
	}
}

func TestStateSaveWithoutResourceVersion(t *testing.T) {
	cm := makeStateCM(map[string]string{"bootstrapped": "true"})
	sm, _ := newTestStateManager(t, cm)

	state := &CoordinatorState{
		// ResourceVersion intentionally empty
		TaskQueue: []int{1, 2, 3},
	}

	err := sm.Save(context.Background(), state)
	if err == nil {
		t.Fatal("expected error for save without ResourceVersion")
	}
}

func TestStateConcurrentUpdate(t *testing.T) {
	cm := makeStateCM(map[string]string{
		"spawnSlots":   "5",
		"bootstrapped": "true",
	})

	sm, fakeClient := newTestStateManager(t, cm)

	// Simulate a conflict on the first two update attempts, then succeed.
	var updateAttempts atomic.Int32
	fakeClient.PrependReactor("update", "configmaps", func(action k8stesting.Action) (bool, runtime.Object, error) {
		attempt := updateAttempts.Add(1)
		if attempt <= 2 {
			return true, nil, k8serrors.NewConflict(
				schema.GroupResource{Resource: "configmaps"},
				StateConfigMapName,
				fmt.Errorf("simulated conflict"),
			)
		}
		// Let the default handler process the update on attempt 3+
		return false, nil, nil
	})

	err := sm.UpdateWithRetry(context.Background(), func(state *CoordinatorState) error {
		state.SpawnSlots = 10
		return nil
	})
	if err != nil {
		t.Fatalf("UpdateWithRetry: %v", err)
	}

	totalAttempts := updateAttempts.Load()
	// We expect 3 update calls: 2 conflicts + 1 success.
	// But Load is also called before each update, and the fake client tracks all
	// calls. We verify the retry happened by checking the total update count.
	if totalAttempts < 3 {
		t.Errorf("expected at least 3 update attempts, got %d", totalAttempts)
	}
}

func TestStateConcurrentUpdateExhausted(t *testing.T) {
	cm := makeStateCM(map[string]string{"bootstrapped": "true"})
	sm, fakeClient := newTestStateManager(t, cm)

	// Always conflict
	fakeClient.PrependReactor("update", "configmaps", func(action k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, k8serrors.NewConflict(
			schema.GroupResource{Resource: "configmaps"},
			StateConfigMapName,
			fmt.Errorf("permanent conflict"),
		)
	})

	err := sm.UpdateWithRetry(context.Background(), func(state *CoordinatorState) error {
		state.SpawnSlots = 10
		return nil
	})
	if err == nil {
		t.Fatal("expected error after exhausting retries")
	}
}

func TestStateConcurrentUpdateMutatorError(t *testing.T) {
	cm := makeStateCM(map[string]string{"bootstrapped": "true"})
	sm, _ := newTestStateManager(t, cm)

	err := sm.UpdateWithRetry(context.Background(), func(state *CoordinatorState) error {
		return fmt.Errorf("mutator failed intentionally")
	})
	if err == nil {
		t.Fatal("expected error from failing mutator")
	}
}

func TestUpdateField(t *testing.T) {
	cm := makeStateCM(map[string]string{
		"spawnSlots":   "5",
		"bootstrapped": "true",
	})
	sm, fakeClient := newTestStateManager(t, cm)

	err := sm.UpdateField(context.Background(), "spawnSlots", "8")
	if err != nil {
		t.Fatalf("UpdateField: %v", err)
	}

	// Verify the patch was applied
	updated, err := fakeClient.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("Getting updated CM: %v", err)
	}
	if updated.Data["spawnSlots"] != "8" {
		t.Errorf("spawnSlots = %q, want %q", updated.Data["spawnSlots"], "8")
	}
}

func TestGetField(t *testing.T) {
	cm := makeStateCM(map[string]string{
		"taskQueue":    "1,2,3",
		"bootstrapped": "true",
	})
	sm, _ := newTestStateManager(t, cm)

	val, err := sm.GetField(context.Background(), "taskQueue")
	if err != nil {
		t.Fatalf("GetField: %v", err)
	}
	if val != "1,2,3" {
		t.Errorf("GetField(taskQueue) = %q, want %q", val, "1,2,3")
	}

	// Missing field returns empty string
	val, err = sm.GetField(context.Background(), "nonexistent")
	if err != nil {
		t.Fatalf("GetField(nonexistent): %v", err)
	}
	if val != "" {
		t.Errorf("GetField(nonexistent) = %q, want empty", val)
	}
}

func TestParseAssignmentsEdgeCases(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  map[string]int
	}{
		{"empty", "", map[string]int{}},
		{"single", "worker-1:42", map[string]int{"worker-1": 42}},
		{"trailing comma", "w1:1,w2:2,", map[string]int{"w1": 1, "w2": 2}},
		{"spaces", " w1 : 1 , w2 : 2 ", map[string]int{"w1": 1, "w2": 2}},
		{"invalid issue", "w1:notanumber", map[string]int{}},
		{"missing colon", "w1", map[string]int{}},
		{"empty agent", ":42", map[string]int{}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseAssignments(tt.input)
			if len(got) != len(tt.want) {
				t.Errorf("parseAssignments(%q) = %v (len %d), want %v (len %d)",
					tt.input, got, len(got), tt.want, len(tt.want))
				return
			}
			for k, v := range tt.want {
				if got[k] != v {
					t.Errorf("parseAssignments(%q)[%q] = %d, want %d", tt.input, k, got[k], v)
				}
			}
		})
	}
}

func TestParseIntList(t *testing.T) {
	tests := []struct {
		input string
		want  []int
	}{
		{"", nil},
		{"1", []int{1}},
		{"1,2,3", []int{1, 2, 3}},
		{"1,,3", []int{1, 3}},    // skip empty
		{"1,abc,3", []int{1, 3}}, // skip non-numeric
		{" 1 , 2 ", []int{1, 2}}, // handle spaces
	}

	for _, tt := range tests {
		got := parseIntList(tt.input)
		if len(got) != len(tt.want) {
			t.Errorf("parseIntList(%q) = %v, want %v", tt.input, got, tt.want)
			continue
		}
		for i := range got {
			if got[i] != tt.want[i] {
				t.Errorf("parseIntList(%q)[%d] = %d, want %d", tt.input, i, got[i], tt.want[i])
			}
		}
	}
}

func TestConcurrentLoadAndUpdate(t *testing.T) {
	cm := makeStateCM(map[string]string{
		"spawnSlots":   "10",
		"bootstrapped": "true",
	})
	sm, _ := newTestStateManager(t, cm)

	// Multiple goroutines loading simultaneously
	var wg sync.WaitGroup
	errCh := make(chan error, 20)

	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			state, err := sm.Load(context.Background())
			if err != nil {
				errCh <- err
				return
			}
			if state.SpawnSlots < 0 {
				errCh <- fmt.Errorf("negative spawn slots: %d", state.SpawnSlots)
			}
		}()
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		t.Errorf("concurrent load error: %v", err)
	}
}
