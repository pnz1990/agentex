package health

import (
	"context"
	"fmt"
	"log/slog"
	"testing"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"

	"github.com/pnz1990/agentex/internal/k8s"
)

const testNamespace = "agentex"

func makeTestClient(t *testing.T, fakeClient *fake.Clientset) *k8s.Client {
	t.Helper()
	return k8s.NewClientFromInterfaces(fakeClient, nil, slog.Default())
}

func makeCoordinatorStateCM(data map[string]string) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            coordinatorStateConfigMap,
			Namespace:       testNamespace,
			ResourceVersion: "1",
		},
		Data: data,
	}
}

func makeKillSwitchCM(enabled bool, reason string) *corev1.ConfigMap {
	e := "false"
	if enabled {
		e = "true"
	}
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            killSwitchConfigMap,
			Namespace:       testNamespace,
			ResourceVersion: "1",
		},
		Data: map[string]string{
			"enabled": e,
			"reason":  reason,
		},
	}
}

// --- CoordinatorHeartbeatCheck tests ---

func TestCoordinatorHeartbeatCheck_Fresh(t *testing.T) {
	now := time.Now().UTC()
	cm := makeCoordinatorStateCM(map[string]string{
		"lastHeartbeat": now.Format(time.RFC3339),
	})

	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewCoordinatorHeartbeatCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusHealthy {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusHealthy, result.Message)
	}
}

func TestCoordinatorHeartbeatCheck_Stale(t *testing.T) {
	stale := time.Now().UTC().Add(-5 * time.Minute)
	cm := makeCoordinatorStateCM(map[string]string{
		"lastHeartbeat": stale.Format(time.RFC3339),
	})

	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewCoordinatorHeartbeatCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusCritical {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusCritical, result.Message)
	}
}

func TestCoordinatorHeartbeatCheck_Missing(t *testing.T) {
	cm := makeCoordinatorStateCM(map[string]string{})

	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewCoordinatorHeartbeatCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusCritical {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusCritical, result.Message)
	}
}

func TestCoordinatorHeartbeatCheck_NoConfigMap(t *testing.T) {
	client := makeTestClient(t, fake.NewSimpleClientset())
	check := NewCoordinatorHeartbeatCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusCritical {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusCritical, result.Message)
	}
}

// --- SpawnSlotConsistencyCheck tests ---

func TestSpawnSlotConsistencyCheck_Valid(t *testing.T) {
	cm := makeCoordinatorStateCM(map[string]string{
		"spawnSlots": "5",
	})
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "worker-1",
			Namespace: testNamespace,
		},
		Status: batchv1.JobStatus{Active: 1},
	}

	client := makeTestClient(t, fake.NewSimpleClientset(cm, job))
	check := NewSpawnSlotConsistencyCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusHealthy {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusHealthy, result.Message)
	}
}

func TestSpawnSlotConsistencyCheck_Negative(t *testing.T) {
	cm := makeCoordinatorStateCM(map[string]string{
		"spawnSlots": "-3",
	})

	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewSpawnSlotConsistencyCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusCritical {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusCritical, result.Message)
	}
}

func TestSpawnSlotConsistencyCheck_InvalidValue(t *testing.T) {
	cm := makeCoordinatorStateCM(map[string]string{
		"spawnSlots": "notanumber",
	})

	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewSpawnSlotConsistencyCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusDegraded {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusDegraded, result.Message)
	}
}

func TestSpawnSlotConsistencyCheck_Mismatch(t *testing.T) {
	cm := makeCoordinatorStateCM(map[string]string{
		"spawnSlots": "45",
	})

	// Create enough active jobs to trigger the >50 check (45 + 10 = 55)
	objs := []runtime.Object{cm}
	for i := range 10 {
		objs = append(objs, &batchv1.Job{
			ObjectMeta: metav1.ObjectMeta{
				Name:      fmt.Sprintf("job-%d", i),
				Namespace: testNamespace,
			},
			Status: batchv1.JobStatus{Active: 1},
		})
	}

	client := makeTestClient(t, fake.NewSimpleClientset(objs...))
	check := NewSpawnSlotConsistencyCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusDegraded {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusDegraded, result.Message)
	}
}

// --- ConfigMapAccumulationCheck tests ---

func TestConfigMapAccumulationCheck_UnderThreshold(t *testing.T) {
	cm1 := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "cm-1", Namespace: testNamespace},
	}
	cm2 := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "cm-2", Namespace: testNamespace},
	}

	client := makeTestClient(t, fake.NewSimpleClientset(cm1, cm2))
	check := NewConfigMapAccumulationCheck(client, testNamespace, 200)
	result := check.Check(context.Background())

	if result.Status != StatusHealthy {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusHealthy, result.Message)
	}
}

func TestConfigMapAccumulationCheck_OverThreshold(t *testing.T) {
	threshold := 5
	objs := make([]runtime.Object, threshold+3)
	for i := range threshold + 3 {
		objs[i] = &corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{
				Name:      fmt.Sprintf("cm-%d", i),
				Namespace: testNamespace,
			},
		}
	}

	client := makeTestClient(t, fake.NewSimpleClientset(objs...))
	check := NewConfigMapAccumulationCheck(client, testNamespace, threshold)
	result := check.Check(context.Background())

	if result.Status != StatusDegraded {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusDegraded, result.Message)
	}
}

// --- KillSwitchCheck tests ---

func TestKillSwitchCheck_Inactive(t *testing.T) {
	cm := makeKillSwitchCM(false, "")

	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewKillSwitchCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusHealthy {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusHealthy, result.Message)
	}
}

func TestKillSwitchCheck_Active(t *testing.T) {
	cm := makeKillSwitchCM(true, "Emergency stop")

	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewKillSwitchCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusCritical {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusCritical, result.Message)
	}
}

func TestKillSwitchCheck_Missing(t *testing.T) {
	client := makeTestClient(t, fake.NewSimpleClientset())
	check := NewKillSwitchCheck(client, testNamespace)
	result := check.Check(context.Background())

	if result.Status != StatusHealthy {
		t.Errorf("Status = %q, want %q (missing = inactive); message: %s", result.Status, StatusHealthy, result.Message)
	}
}

// --- StaleAssignmentCheck tests ---

func TestStaleAssignmentCheck_NoAssignments(t *testing.T) {
	cm := makeCoordinatorStateCM(map[string]string{
		"activeAssignments": "",
	})

	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewStaleAssignmentCheck(client, testNamespace, 30*time.Minute)
	result := check.Check(context.Background())

	if result.Status != StatusHealthy {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusHealthy, result.Message)
	}
}

func TestStaleAssignmentCheck_AllFresh(t *testing.T) {
	cm := makeCoordinatorStateCM(map[string]string{
		"activeAssignments": "worker-1:100",
	})
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:              "worker-1",
			Namespace:         testNamespace,
			CreationTimestamp: metav1.Now(),
		},
		Status: batchv1.JobStatus{Active: 1},
	}

	client := makeTestClient(t, fake.NewSimpleClientset(cm, job))
	check := NewStaleAssignmentCheck(client, testNamespace, 30*time.Minute)
	result := check.Check(context.Background())

	if result.Status != StatusHealthy {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusHealthy, result.Message)
	}
}

func TestStaleAssignmentCheck_StaleNoJob(t *testing.T) {
	cm := makeCoordinatorStateCM(map[string]string{
		"activeAssignments": "worker-ghost:100",
	})

	// No job exists for worker-ghost
	client := makeTestClient(t, fake.NewSimpleClientset(cm))
	check := NewStaleAssignmentCheck(client, testNamespace, 30*time.Minute)
	result := check.Check(context.Background())

	if result.Status != StatusDegraded {
		t.Errorf("Status = %q, want %q; message: %s", result.Status, StatusDegraded, result.Message)
	}
}

// --- Monitor tests ---

func TestMonitorRunsAllChecks(t *testing.T) {
	now := time.Now().UTC()
	stateCM := makeCoordinatorStateCM(map[string]string{
		"lastHeartbeat":     now.Format(time.RFC3339),
		"spawnSlots":        "3",
		"activeAssignments": "",
	})
	ksCM := makeKillSwitchCM(false, "")

	client := makeTestClient(t, fake.NewSimpleClientset(stateCM, ksCM))
	logger := slog.Default()

	monitor := NewMonitor(client, testNamespace, time.Minute, logger)
	report := monitor.RunOnce(context.Background())

	if len(report.Checks) != 5 {
		t.Errorf("expected 5 checks, got %d", len(report.Checks))
		for _, check := range report.Checks {
			t.Logf("  %s: %s (%s)", check.Name, check.Status, check.Message)
		}
	}

	for _, check := range report.Checks {
		if check.Name == "" {
			t.Error("check has empty name")
		}
		if check.CheckedAt.IsZero() {
			t.Errorf("check %q has zero CheckedAt", check.Name)
		}
	}
}

func TestMonitorAddCheck(t *testing.T) {
	client := makeTestClient(t, fake.NewSimpleClientset(
		makeCoordinatorStateCM(map[string]string{
			"lastHeartbeat": time.Now().UTC().Format(time.RFC3339),
			"spawnSlots":    "3",
		}),
	))
	logger := slog.Default()

	monitor := NewMonitor(client, testNamespace, time.Minute, logger)
	monitor.AddCheck(&mockCheck{
		name:   "custom-check",
		status: StatusHealthy,
		msg:    "all good",
	})

	report := monitor.RunOnce(context.Background())

	// Should have 5 built-in + 1 custom
	if len(report.Checks) != 6 {
		t.Errorf("expected 6 checks, got %d", len(report.Checks))
	}

	found := false
	for _, check := range report.Checks {
		if check.Name == "custom-check" {
			found = true
			if check.Status != StatusHealthy {
				t.Errorf("custom check Status = %q, want %q", check.Status, StatusHealthy)
			}
		}
	}
	if !found {
		t.Error("custom check not found in report")
	}
}

// --- Report overall status tests ---

func TestReportOverallStatus_AllHealthy(t *testing.T) {
	checks := []Check{
		{Name: "a", Status: StatusHealthy},
		{Name: "b", Status: StatusHealthy},
		{Name: "c", Status: StatusHealthy},
	}

	got := worstStatus(checks)
	if got != StatusHealthy {
		t.Errorf("worstStatus = %q, want %q", got, StatusHealthy)
	}
}

func TestReportOverallStatus_OneDegraded(t *testing.T) {
	checks := []Check{
		{Name: "a", Status: StatusHealthy},
		{Name: "b", Status: StatusDegraded},
		{Name: "c", Status: StatusHealthy},
	}

	got := worstStatus(checks)
	if got != StatusDegraded {
		t.Errorf("worstStatus = %q, want %q", got, StatusDegraded)
	}
}

func TestReportOverallStatus_OneCritical(t *testing.T) {
	checks := []Check{
		{Name: "a", Status: StatusHealthy},
		{Name: "b", Status: StatusDegraded},
		{Name: "c", Status: StatusCritical},
	}

	got := worstStatus(checks)
	if got != StatusCritical {
		t.Errorf("worstStatus = %q, want %q", got, StatusCritical)
	}
}

func TestReportOverallStatus_Empty(t *testing.T) {
	got := worstStatus(nil)
	if got != StatusHealthy {
		t.Errorf("worstStatus(nil) = %q, want %q", got, StatusHealthy)
	}
}

// --- helpers ---

type mockCheck struct {
	name   string
	status Status
	msg    string
}

func (m *mockCheck) Name() string { return m.name }
func (m *mockCheck) Check(_ context.Context) Check {
	return Check{
		Name:      m.name,
		Status:    m.status,
		Message:   m.msg,
		CheckedAt: time.Now().UTC(),
	}
}
