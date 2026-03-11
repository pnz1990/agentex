package coordinator

import (
	"context"
	"fmt"
	"log/slog"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	k8sfake "k8s.io/client-go/kubernetes/fake"

	"github.com/pnz1990/agentex/internal/config"
	k8sclient "github.com/pnz1990/agentex/internal/k8s"
	"github.com/pnz1990/agentex/internal/metrics"
)

// fakeGitHubFetcher is a test double for GitHubIssueFetcher.
type fakeGitHubFetcher struct {
	Issues []GitHubIssue
	Err    error
	Called int
}

func (f *fakeGitHubFetcher) FetchOpenIssues(_ context.Context, _ string, _ int) ([]GitHubIssue, error) {
	f.Called++
	return f.Issues, f.Err
}

// testLogger returns the default slog logger for tests.
func testLogger(_ *testing.T) *slog.Logger {
	return slog.Default()
}

// newFakeDynamic creates a fake dynamic client with the kro CRDs registered.
func newFakeDynamic() *dynamicfake.FakeDynamicClient {
	scheme := runtime.NewScheme()
	// Register kro GVRs so fake dynamic client accepts creates.
	for _, gvr := range []schema.GroupVersionResource{
		k8sclient.AgentGVR, k8sclient.TaskGVR,
	} {
		scheme.AddKnownTypeWithName(
			schema.GroupVersionKind{Group: gvr.Group, Version: gvr.Version, Kind: ""},
			&runtime.Unknown{},
		)
	}
	return dynamicfake.NewSimpleDynamicClient(scheme)
}

// newTestCoordinatorWithFetcher creates a coordinator with a fake GitHub fetcher.
func newTestCoordinatorWithFetcher(t *testing.T, fetcher GitHubIssueFetcher, objects ...runtime.Object) (*Coordinator, *k8sfake.Clientset) {
	t.Helper()
	logger := testLogger(t)

	fakeClientset := k8sfake.NewSimpleClientset(objects...)
	client := k8sclient.NewClientFromInterfaces(fakeClientset, nil, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)

	coord := &Coordinator{
		client:        client,
		namespace:     "agentex",
		config:        cfg,
		stateManager:  NewStateManager(client, "agentex", logger),
		githubFetcher: fetcher,
		logger:        logger,
		stopCh:        make(chan struct{}),
	}
	return coord, fakeClientset
}

// newTestCoordWithDynamic creates a coordinator with both fake k8s and fake dynamic clients.
func newTestCoordWithDynamic(t *testing.T, fetcher GitHubIssueFetcher, objects ...runtime.Object) *Coordinator {
	t.Helper()
	logger := testLogger(t)

	fakeClientset := k8sfake.NewSimpleClientset(objects...)
	fakeDyn := newFakeDynamic()
	client := k8sclient.NewClientFromInterfaces(fakeClientset, fakeDyn, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)

	coord := &Coordinator{
		client:        client,
		namespace:     "agentex",
		config:        cfg,
		stateManager:  NewStateManager(client, "agentex", logger),
		githubFetcher: fetcher,
		logger:        logger,
		stopCh:        make(chan struct{}),
	}
	return coord
}

// --- refreshTaskQueue tests (#2056) ---

func TestRefreshTaskQueue(t *testing.T) {
	constitutionCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            config.ConstitutionConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
		},
		Data: map[string]string{
			"circuitBreakerLimit": "6",
			"githubRepo":          "owner/repo",
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
			"bootstrapped":      "true",
			"spawnSlots":        "6",
			"activeAssignments": "",
			"visionQueue":       "",
			"taskQueue":         "",
		},
	}

	fetcher := &fakeGitHubFetcher{
		Issues: []GitHubIssue{
			{Number: 42, Title: "Fix bug", Labels: []string{"bug"}},
			{Number: 99, Title: "Improve governance", Labels: []string{"governance"}},
			{Number: 7, Title: "Random task", Labels: []string{}},
		},
	}

	coord, fakeClient := newTestCoordinatorWithFetcher(t, fetcher, constitutionCM, stateCM)

	if err := coord.config.LoadFromConfigMap(constitutionCM); err != nil {
		t.Fatalf("loading constitution: %v", err)
	}

	if err := coord.refreshTaskQueue(context.Background()); err != nil {
		t.Fatalf("refreshTaskQueue: %v", err)
	}

	if fetcher.Called != 1 {
		t.Errorf("expected 1 GitHub API call, got %d", fetcher.Called)
	}

	cm, err := fakeClient.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("getting state: %v", err)
	}

	queue := parseIntList(cm.Data["taskQueue"])
	if len(queue) == 0 {
		t.Fatal("task queue should not be empty after refresh")
	}

	// Issue 99 has "governance" label (score=9) — should be first
	if queue[0] != 99 {
		t.Errorf("expected issue 99 (governance) first, got %d", queue[0])
	}
	// Issue 7 has no label (defaultVisionScore=5) — should come before issue 42 (bug=4)
	if queue[1] != 7 {
		t.Errorf("expected issue 7 (score=5) second, got %d", queue[1])
	}
	// Issue 42 has "bug" label (score=4) — last
	if queue[2] != 42 {
		t.Errorf("expected issue 42 (bug, score=4) third, got %d", queue[2])
	}
}

func TestRefreshTaskQueueFiltersAssigned(t *testing.T) {
	constitutionCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            config.ConstitutionConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
		},
		Data: map[string]string{
			"circuitBreakerLimit": "6",
			"githubRepo":          "owner/repo",
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
			"bootstrapped":      "true",
			"spawnSlots":        "5",
			"activeAssignments": "some-agent:99", // issue 99 already assigned
			"visionQueue":       "",
			"taskQueue":         "",
		},
	}

	fetcher := &fakeGitHubFetcher{
		Issues: []GitHubIssue{
			{Number: 99, Title: "Already assigned", Labels: []string{"governance"}},
			{Number: 42, Title: "Free issue", Labels: []string{"bug"}},
		},
	}

	coord, fakeClient := newTestCoordinatorWithFetcher(t, fetcher, constitutionCM, stateCM)
	if err := coord.config.LoadFromConfigMap(constitutionCM); err != nil {
		t.Fatalf("loading constitution: %v", err)
	}

	if err := coord.refreshTaskQueue(context.Background()); err != nil {
		t.Fatalf("refreshTaskQueue: %v", err)
	}

	cm, _ := fakeClient.CoreV1().ConfigMaps("agentex").Get(
		context.Background(), StateConfigMapName, metav1.GetOptions{},
	)
	queue := parseIntList(cm.Data["taskQueue"])

	for _, n := range queue {
		if n == 99 {
			t.Error("issue 99 should have been filtered out (already assigned)")
		}
	}
}

func TestRefreshTaskQueueSkipsWhenNoRepo(t *testing.T) {
	constitutionCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            config.ConstitutionConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
		},
		Data: map[string]string{
			"circuitBreakerLimit": "6",
			"voteThreshold":       "3",
			// githubRepo intentionally absent — should skip fetch
		},
	}
	stateCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{"bootstrapped": "true"},
	}

	fetcher := &fakeGitHubFetcher{}
	coord, _ := newTestCoordinatorWithFetcher(t, fetcher, constitutionCM, stateCM)
	if err := coord.config.LoadFromConfigMap(constitutionCM); err != nil {
		t.Fatalf("loading constitution: %v", err)
	}

	if err := coord.refreshTaskQueue(context.Background()); err != nil {
		t.Fatalf("refreshTaskQueue: %v", err)
	}

	if fetcher.Called != 0 {
		t.Errorf("expected 0 GitHub API calls when repo not set, got %d", fetcher.Called)
	}
}

func TestRefreshTaskQueueFetchError(t *testing.T) {
	constitutionCM := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            config.ConstitutionConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
		},
		Data: map[string]string{
			"circuitBreakerLimit": "6",
			"githubRepo":          "owner/repo",
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
		Data: map[string]string{"bootstrapped": "true"},
	}

	fetcher := &fakeGitHubFetcher{Err: fmt.Errorf("network error")}
	coord, _ := newTestCoordinatorWithFetcher(t, fetcher, constitutionCM, stateCM)
	if err := coord.config.LoadFromConfigMap(constitutionCM); err != nil {
		t.Fatalf("loading constitution: %v", err)
	}

	err := coord.refreshTaskQueue(context.Background())
	if err == nil {
		t.Fatal("expected error from refreshTaskQueue when fetcher fails")
	}
}

// --- dispatchNextTask tests (#2057) ---

func TestDispatchNextTask_NoSlotsNoDispatch(t *testing.T) {
	stateCM := stateWithQueue([]int{100, 200}, 0 /* no slots */)

	coord := newTestCoordWithDynamic(t, &fakeGitHubFetcher{}, killSwitchCM(false), stateCM)

	if err := coord.dispatchNextTask(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDispatchNextTask_EmptyQueueNoDispatch(t *testing.T) {
	stateCM := stateWithQueue([]int{}, 3)

	coord := newTestCoordWithDynamic(t, &fakeGitHubFetcher{}, killSwitchCM(false), stateCM)

	if err := coord.dispatchNextTask(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDispatchNextTask_KillSwitchBlocks(t *testing.T) {
	stateCM := stateWithQueue([]int{42}, 3)
	ks := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agentex-killswitch",
			Namespace: "agentex",
		},
		Data: map[string]string{
			"enabled": "true",
			"reason":  "emergency stop",
		},
	}

	reg := metrics.NewRegistry()
	m := RegisterMetrics(reg)
	coord := newTestCoordWithDynamic(t, &fakeGitHubFetcher{}, stateCM, ks)
	coord.metrics = m

	if err := coord.dispatchNextTask(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if m.SpawnBlocked.GetValue() != 1 {
		t.Errorf("SpawnBlocked = %v, want 1", m.SpawnBlocked.GetValue())
	}
}

func TestDispatchNextTask_AllAssignedNoDispatch(t *testing.T) {
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
			"taskQueue":         "42",
			"activeAssignments": "some-agent:42", // 42 already assigned
			"visionQueue":       "",
		},
	}

	coord := newTestCoordWithDynamic(t, &fakeGitHubFetcher{}, killSwitchCM(false), stateCM)

	if err := coord.dispatchNextTask(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDispatchNextTask_DispatchesWhenAvailable(t *testing.T) {
	stateCM := stateWithQueue([]int{100}, 3)
	constitutionCM := defaultConstitutionCM()

	fakeDyn := newFakeDynamic()
	fakeClientset := k8sfake.NewSimpleClientset(constitutionCM, stateCM, killSwitchCM(false))
	logger := testLogger(t)
	client := k8sclient.NewClientFromInterfaces(fakeClientset, fakeDyn, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)
	if err := cfg.LoadFromConfigMap(constitutionCM); err != nil {
		t.Fatalf("loading constitution: %v", err)
	}

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
	}

	if err := coord.dispatchNextTask(context.Background()); err != nil {
		t.Fatalf("dispatchNextTask: %v", err)
	}

	if m.AgentsSpawned.GetValue() != 1 {
		t.Errorf("AgentsSpawned = %v, want 1", m.AgentsSpawned.GetValue())
	}
	if m.TasksClaimed.GetValue() != 1 {
		t.Errorf("TasksClaimed = %v, want 1", m.TasksClaimed.GetValue())
	}
}

// --- Metrics wiring tests (#2058) ---

func TestMetricsWiredIntoTick(t *testing.T) {
	constitutionCM := defaultConstitutionCM()
	stateCM := defaultStateCM()

	fakeClientset := k8sfake.NewSimpleClientset(constitutionCM, stateCM, killSwitchCM(false))
	fakeDyn := newFakeDynamic()
	logger := testLogger(t)
	client := k8sclient.NewClientFromInterfaces(fakeClientset, fakeDyn, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)
	if err := cfg.LoadFromConfigMap(constitutionCM); err != nil {
		t.Fatalf("loading constitution: %v", err)
	}

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
	}

	coord.tick(context.Background(), 1)

	if m.ReconcileTotal.GetValue() != 1 {
		t.Errorf("ReconcileTotal = %v, want 1", m.ReconcileTotal.GetValue())
	}
	if m.ReconcileDuration.GetValue() <= 0 {
		t.Errorf("ReconcileDuration should be > 0, got %v", m.ReconcileDuration.GetValue())
	}
	if m.CircuitBreakerLimit.GetValue() != 6 {
		t.Errorf("CircuitBreakerLimit = %v, want 6", m.CircuitBreakerLimit.GetValue())
	}
	if m.KillSwitchActive.GetValue() != 0 {
		t.Errorf("KillSwitchActive = %v, want 0", m.KillSwitchActive.GetValue())
	}
}

func TestMetricsMultipleTicks(t *testing.T) {
	constitutionCM := defaultConstitutionCM()
	stateCM := defaultStateCM()

	fakeClientset := k8sfake.NewSimpleClientset(constitutionCM, stateCM, killSwitchCM(false))
	fakeDyn := newFakeDynamic()
	logger := testLogger(t)
	client := k8sclient.NewClientFromInterfaces(fakeClientset, fakeDyn, logger)
	cfg := config.NewConfig("agentex", 50*time.Millisecond, "", logger)
	if err := cfg.LoadFromConfigMap(constitutionCM); err != nil {
		t.Fatalf("loading constitution: %v", err)
	}

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
	}

	for i := 1; i <= 5; i++ {
		coord.tick(context.Background(), i)
	}

	if m.ReconcileTotal.GetValue() != 5 {
		t.Errorf("ReconcileTotal after 5 ticks = %v, want 5", m.ReconcileTotal.GetValue())
	}
}

// --- helper functions ---

func stateWithQueue(queue []int, spawnSlots int) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1",
			Labels:          map[string]string{"agentex/component": "coordinator"},
		},
		Data: map[string]string{
			"bootstrapped":      "true",
			"spawnSlots":        fmt.Sprintf("%d", spawnSlots),
			"taskQueue":         formatIntList(queue),
			"activeAssignments": "",
			"visionQueue":       "",
		},
	}
}

func killSwitchCM(enabled bool) *corev1.ConfigMap {
	val := "false"
	if enabled {
		val = "true"
	}
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "agentex-killswitch",
			Namespace: "agentex",
		},
		Data: map[string]string{
			"enabled": val,
			"reason":  "",
		},
	}
}

func TestIssueNumberName(t *testing.T) {
	tests := []struct {
		issue  int
		prefix string
		want   string
	}{
		{42, "task", "task-issue-42"},
		{1234, "worker", "worker-issue-1234"},
	}
	for _, tt := range tests {
		got := issueNumberName(tt.issue, tt.prefix)
		if got != tt.want {
			t.Errorf("issueNumberName(%d, %q) = %q, want %q", tt.issue, tt.prefix, got, tt.want)
		}
	}
}

// Ensure time import is used.
var _ = time.Second
