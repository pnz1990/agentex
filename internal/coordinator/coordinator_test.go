package coordinator

import (
	"context"
	"log/slog"
	"testing"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"

	"github.com/pnz1990/agentex/internal/config"
	k8sclient "github.com/pnz1990/agentex/internal/k8s"
)

// defaultConstitutionCM returns a minimal constitution ConfigMap for tests.
func defaultConstitutionCM() *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            config.ConstitutionConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
		},
		Data: map[string]string{
			"circuitBreakerLimit":    "6",
			"githubRepo":             "pnz1990/agentex",
			"awsRegion":              "us-west-2",
			"clusterName":            "agentex",
			"s3Bucket":               "agentex-thoughts",
			"voteThreshold":          "3",
			"civilizationGeneration": "4",
		},
	}
}

// defaultStateCM returns a minimal coordinator-state ConfigMap for tests.
func defaultStateCM() *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels: map[string]string{
				"agentex/component": "coordinator",
			},
		},
		Data: map[string]string{
			"bootstrapped": "true",
			"spawnSlots":   "6",
		},
	}
}

// newTestCoordinatorWithObjects creates a Coordinator for testing with the given k8s objects.
func newTestCoordinatorWithObjects(t *testing.T, objects ...runtime.Object) (*Coordinator, *fake.Clientset) {
	t.Helper()
	logger := slog.Default()

	fakeClient := fake.NewSimpleClientset(objects...)
	client := k8sclient.NewClientFromInterfaces(fakeClient, nil, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)

	coord := NewCoordinator(client, cfg, logger)
	return coord, fakeClient
}

func TestNewCoordinator(t *testing.T) {
	logger := slog.Default()
	fakeClient := fake.NewSimpleClientset()
	client := k8sclient.NewClientFromInterfaces(fakeClient, nil, logger)
	cfg := config.NewConfig("agentex", 30*time.Second, "", logger)

	coord := NewCoordinator(client, cfg, logger)

	if coord == nil {
		t.Fatal("NewCoordinator returned nil")
	}
	if coord.namespace != "agentex" {
		t.Errorf("namespace = %q, want %q", coord.namespace, "agentex")
	}
	if coord.stateManager == nil {
		t.Error("stateManager is nil")
	}
	if coord.stopCh == nil {
		t.Error("stopCh is nil")
	}
}

func TestCoordinatorStartStop(t *testing.T) {
	coord, fakeClient := newTestCoordinatorWithObjects(t,
		defaultConstitutionCM(),
		defaultStateCM(),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Run coordinator in a goroutine
	errCh := make(chan error, 1)
	go func() {
		errCh <- coord.Run(ctx)
	}()

	// Let it run for a few ticks
	time.Sleep(200 * time.Millisecond)

	// Stop the coordinator
	coord.Stop()

	// Wait for it to finish
	select {
	case err := <-errCh:
		if err != nil {
			t.Logf("coordinator exited with: %v (expected nil on stop)", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("coordinator did not stop within 2 seconds")
	}

	// Verify heartbeat was written
	cm, err := fakeClient.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("getting state CM: %v", err)
	}
	if cm.Data["lastHeartbeat"] == "" {
		t.Error("lastHeartbeat was not written")
	}
}

func TestCoordinatorContextCancellation(t *testing.T) {
	coord, _ := newTestCoordinatorWithObjects(t,
		defaultConstitutionCM(),
		defaultStateCM(),
	)

	ctx, cancel := context.WithCancel(context.Background())

	errCh := make(chan error, 1)
	go func() {
		errCh <- coord.Run(ctx)
	}()

	time.Sleep(150 * time.Millisecond)
	cancel()

	select {
	case err := <-errCh:
		if err != nil && err != context.Canceled {
			t.Errorf("expected context.Canceled, got: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("coordinator did not stop on context cancellation")
	}
}

func TestCleanupStaleAssignments(t *testing.T) {
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped":      "true",
			"activeAssignments": "active-worker:100,stale-worker:200",
			"spawnSlots":        "6",
		},
	}

	// Create a running job for active-worker, none for stale-worker
	activeJob := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "active-worker",
			Namespace: "agentex",
		},
		Status: batchv1.JobStatus{
			Active: 1,
			// CompletionTime is nil = still running
		},
	}

	coord, fakeClient := newTestCoordinatorWithObjects(t,
		defaultConstitutionCM(),
		stateCM,
		activeJob,
	)

	err := coord.cleanupStaleAssignments(context.Background())
	if err != nil {
		t.Fatalf("cleanupStaleAssignments: %v", err)
	}

	// Verify stale-worker was removed, active-worker kept
	cm, err := fakeClient.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("getting state: %v", err)
	}

	assignments := parseAssignments(cm.Data["activeAssignments"])
	if _, ok := assignments["active-worker"]; !ok {
		t.Error("active-worker should still be assigned")
	}
	if _, ok := assignments["stale-worker"]; ok {
		t.Error("stale-worker should have been removed")
	}
}

func TestReconcileSpawnSlots(t *testing.T) {
	constitutionCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            config.ConstitutionConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
		},
		Data: map[string]string{
			"circuitBreakerLimit": "10",
			"githubRepo":          "pnz1990/agentex",
			"voteThreshold":       "3",
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
			"spawnSlots":   "0", // Wrong — should be 10 - 3 = 7
		},
	}

	// 3 active jobs + 1 completed (should not count)
	completedTime := metav1.Now()
	coord, fakeClient := newTestCoordinatorWithObjects(t,
		constitutionCM,
		stateCM,
		&batchv1.Job{
			ObjectMeta: metav1.ObjectMeta{Name: "job-1", Namespace: "agentex"},
			Status:     batchv1.JobStatus{Active: 1},
		},
		&batchv1.Job{
			ObjectMeta: metav1.ObjectMeta{Name: "job-2", Namespace: "agentex"},
			Status:     batchv1.JobStatus{Active: 1},
		},
		&batchv1.Job{
			ObjectMeta: metav1.ObjectMeta{Name: "job-3", Namespace: "agentex"},
			Status:     batchv1.JobStatus{Active: 1},
		},
		&batchv1.Job{
			ObjectMeta: metav1.ObjectMeta{Name: "job-4", Namespace: "agentex"},
			Status: batchv1.JobStatus{
				CompletionTime: &completedTime,
				Succeeded:      1,
			},
		},
	)

	// Load constitution into config
	if err := coord.config.LoadFromConfigMap(constitutionCM); err != nil {
		t.Fatalf("loading constitution: %v", err)
	}

	err := coord.reconcileSpawnSlots(context.Background())
	if err != nil {
		t.Fatalf("reconcileSpawnSlots: %v", err)
	}

	// Verify spawn slots = 10 - 3 = 7
	cm, err := fakeClient.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("getting state: %v", err)
	}

	if cm.Data["spawnSlots"] != "7" {
		t.Errorf("spawnSlots = %q, want %q", cm.Data["spawnSlots"], "7")
	}
}

func TestHeartbeat(t *testing.T) {
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{"bootstrapped": "true"},
	}

	coord, fakeClient := newTestCoordinatorWithObjects(t, stateCM)

	before := time.Now().UTC()
	err := coord.heartbeat(context.Background())
	if err != nil {
		t.Fatalf("heartbeat: %v", err)
	}

	cm, err := fakeClient.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("getting state: %v", err)
	}

	ts, err := time.Parse(time.RFC3339, cm.Data["lastHeartbeat"])
	if err != nil {
		t.Fatalf("parsing heartbeat timestamp: %v", err)
	}

	if ts.Before(before.Add(-time.Second)) {
		t.Errorf("heartbeat timestamp %v is before test start %v", ts, before)
	}
}

func TestIsJobRunning(t *testing.T) {
	tests := []struct {
		name string
		job  batchv1.Job
		want bool
	}{
		{
			name: "active job",
			job: batchv1.Job{
				Status: batchv1.JobStatus{Active: 1},
			},
			want: true,
		},
		{
			name: "completed job",
			job: batchv1.Job{
				Status: batchv1.JobStatus{
					CompletionTime: &metav1.Time{Time: time.Now()},
					Succeeded:      1,
				},
			},
			want: false,
		},
		{
			name: "no active pods",
			job: batchv1.Job{
				Status: batchv1.JobStatus{Active: 0},
			},
			want: false,
		},
		{
			name: "completed with active (edge case)",
			job: batchv1.Job{
				Status: batchv1.JobStatus{
					CompletionTime: &metav1.Time{Time: time.Now()},
					Active:         1,
				},
			},
			want: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isJobRunning(&tt.job)
			if got != tt.want {
				t.Errorf("isJobRunning() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestIsValidNonNegativeInt(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"0", true},
		{"5", true},
		{"10", true},
		{"-1", false},
		{"", false},
		{"abc", false},
		{" 5 ", true},
		{"5 ", true},
	}

	for _, tt := range tests {
		got := isValidNonNegativeInt(tt.input)
		if got != tt.want {
			t.Errorf("isValidNonNegativeInt(%q) = %v, want %v", tt.input, got, tt.want)
		}
	}
}
