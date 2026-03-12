//go:build e2e

// Package harness provides helpers for agentex e2e / flight tests.
// Tests run against a real Kubernetes cluster (kind + kro) with the
// coordinator deployed and mock agents (AGENTEX_FLIGHT_TEST=true).
package harness

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/pnz1990/agentex/internal/k8s"
)

const (
	// DefaultNamespace is the namespace used for all e2e test resources.
	DefaultNamespace = "agentex-e2e"
	// CoordinatorStateMap is the name of the coordinator state ConfigMap.
	CoordinatorStateMap = "coordinator-state"
	// ConstitutionMap is the name of the constitution ConfigMap.
	ConstitutionMap = "agentex-constitution"
	// KillswitchMap is the name of the killswitch ConfigMap.
	KillswitchMap = "agentex-killswitch"
)

// Cluster wraps a k8s.Client for e2e test operations.
type Cluster struct {
	Client    *k8s.Client
	Namespace string
	Logger    *slog.Logger
	// RunID is a short unique suffix added to all resource names to prevent
	// collisions across test runs when the staging namespace is persistent.
	RunID string
}

// New creates a Cluster from the current KUBECONFIG / in-cluster config.
// If E2E_NAMESPACE is set, it uses that namespace; otherwise DefaultNamespace.
func New(t *testing.T) *Cluster {
	t.Helper()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	kubeconfig := os.Getenv("KUBECONFIG")
	client, err := k8s.NewClient(kubeconfig, logger)
	if err != nil {
		t.Fatalf("harness: create k8s client: %v", err)
	}

	ns := os.Getenv("E2E_NAMESPACE")
	if ns == "" {
		ns = DefaultNamespace
	}

	// Generate a short run ID from the current Unix timestamp (last 6 digits)
	// to make all resource names unique per test run.
	runID := fmt.Sprintf("%06d", time.Now().Unix()%1000000)

	return &Cluster{
		Client:    client,
		Namespace: ns,
		Logger:    logger,
		RunID:     runID,
	}
}

// Name returns a run-scoped resource name by appending RunID.
// Use this for all Job, Task CR, and Report CR names to avoid collisions.
func (c *Cluster) Name(base string) string {
	return fmt.Sprintf("%s-%s", base, c.RunID)
}

// Setup creates the test namespace and applies baseline fixtures.
// It is idempotent: safe to call multiple times.
func (c *Cluster) Setup(ctx context.Context, t *testing.T) {
	t.Helper()
	c.ensureNamespace(ctx, t)
	c.applyConstitution(ctx, t)
	c.applyKillswitchInactive(ctx, t)
	c.ensureCoordinatorState(ctx, t)
}

// Teardown cleans up per-test resources (Jobs, Reports, Tasks tagged with
// agentex/e2e=true) and resets coordinator-state for the next test run.
// It does NOT delete the namespace — the staging namespace is persistent.
func (c *Cluster) Teardown(ctx context.Context, t *testing.T) {
	t.Helper()
	c.Logger.Info("teardown: cleaning up test resources", "namespace", c.Namespace)

	// Delete mock agent Jobs (labeled agentex/e2e=true)
	err := c.Client.Clientset.BatchV1().Jobs(c.Namespace).DeleteCollection(ctx,
		metav1.DeleteOptions{},
		metav1.ListOptions{LabelSelector: "agentex/e2e=true"},
	)
	if err != nil && !k8serrors.IsNotFound(err) {
		t.Logf("teardown: delete jobs: %v", err)
	}

	// Delete all Report CRs
	if reports, listErr := c.Client.ListCRs(ctx, c.Namespace, k8s.ReportGVR, metav1.ListOptions{}); listErr == nil {
		for _, r := range reports.Items {
			_ = c.Client.DeleteCR(ctx, c.Namespace, k8s.ReportGVR, r.GetName())
		}
	}

	// Delete mock Task CRs
	if tasks, listErr := c.Client.ListCRs(ctx, c.Namespace, k8s.TaskGVR, metav1.ListOptions{}); listErr == nil {
		for _, task := range tasks.Items {
			_ = c.Client.DeleteCR(ctx, c.Namespace, k8s.TaskGVR, task.GetName())
		}
	}

	// Reset coordinator-state for the next test
	resetData := map[string]interface{}{
		"data": map[string]string{
			"taskQueue":         "",
			"activeAssignments": "",
			"spawnSlots":        "5",
			"activeAgents":      "",
		},
	}
	resetBytes, _ := json.Marshal(resetData)
	if _, patchErr := c.Client.PatchConfigMap(ctx, c.Namespace, CoordinatorStateMap, resetBytes); patchErr != nil {
		t.Logf("teardown: reset coordinator-state: %v", patchErr)
	}
}

// WaitReady polls until condition returns true or timeout is reached.
func (c *Cluster) WaitReady(ctx context.Context, t *testing.T, desc string, timeout time.Duration, condition func() (bool, error)) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		ok, err := condition()
		if err != nil {
			t.Fatalf("WaitReady %s: %v", desc, err)
		}
		if ok {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("WaitReady %s: timed out after %s", desc, timeout)
		}
		select {
		case <-ctx.Done():
			t.Fatalf("WaitReady %s: context cancelled", desc)
		case <-time.After(2 * time.Second):
		}
	}
}

// ensureNamespace creates the test namespace if it doesn't exist.
func (c *Cluster) ensureNamespace(ctx context.Context, t *testing.T) {
	t.Helper()
	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: c.Namespace,
			Labels: map[string]string{
				"agentex/e2e": "true",
			},
		},
	}
	_, err := c.Client.Clientset.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{})
	if err != nil && !k8serrors.IsAlreadyExists(err) {
		t.Fatalf("harness: create namespace %s: %v", c.Namespace, err)
	}
}

// applyConstitution creates the agentex-constitution ConfigMap with e2e defaults.
func (c *Cluster) applyConstitution(ctx context.Context, t *testing.T) {
	t.Helper()

	// Read constitution values from env so tests are portable.
	githubRepo := envOrDefault("GITHUB_REPO", "pnz1990/agentex")
	ecrRegistry := envOrDefault("ECR_REGISTRY", "569190534191.dkr.ecr.us-west-2.amazonaws.com")
	awsRegion := envOrDefault("AWS_REGION", "us-west-2")
	clusterName := envOrDefault("CLUSTER_NAME", "agentex")
	s3Bucket := envOrDefault("S3_BUCKET", "agentex-thoughts")

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ConstitutionMap,
			Namespace: c.Namespace,
		},
		Data: map[string]string{
			"circuitBreakerLimit":    "5",
			"vision":                 "e2e test civilization",
			"civilizationGeneration": "0",
			"githubRepo":             githubRepo,
			"ecrRegistry":            ecrRegistry,
			"awsRegion":              awsRegion,
			"clusterName":            clusterName,
			"s3Bucket":               s3Bucket,
			"lastDirective":          "run e2e tests",
		},
	}

	_, err := c.Client.Clientset.CoreV1().ConfigMaps(c.Namespace).Create(ctx, cm, metav1.CreateOptions{})
	if err != nil {
		if k8serrors.IsAlreadyExists(err) {
			return
		}
		t.Fatalf("harness: apply constitution: %v", err)
	}
}

// applyKillswitchInactive creates the killswitch ConfigMap with enabled=false.
// The killswitch MUST be off during e2e tests so agents can spawn.
func (c *Cluster) applyKillswitchInactive(ctx context.Context, t *testing.T) {
	t.Helper()
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      KillswitchMap,
			Namespace: c.Namespace,
		},
		Data: map[string]string{
			"enabled": "false",
			"reason":  "",
		},
	}
	_, err := c.Client.Clientset.CoreV1().ConfigMaps(c.Namespace).Create(ctx, cm, metav1.CreateOptions{})
	if err != nil && !k8serrors.IsAlreadyExists(err) {
		t.Fatalf("harness: apply killswitch: %v", err)
	}
}

// ensureCoordinatorState creates the coordinator-state ConfigMap if absent.
func (c *Cluster) ensureCoordinatorState(ctx context.Context, t *testing.T) {
	t.Helper()
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      CoordinatorStateMap,
			Namespace: c.Namespace,
			Labels: map[string]string{
				"agentex/component": "coordinator",
			},
		},
		Data: map[string]string{
			"bootstrapped":      "true",
			"taskQueue":         "",
			"activeAssignments": "",
			"spawnSlots":        "5",
			"visionQueue":       "",
			"activeAgents":      "",
			"lastHeartbeat":     "",
		},
	}
	_, err := c.Client.Clientset.CoreV1().ConfigMaps(c.Namespace).Create(ctx, cm, metav1.CreateOptions{})
	if err != nil && !k8serrors.IsAlreadyExists(err) {
		t.Fatalf("harness: ensure coordinator state: %v", err)
	}
}

// ReadCoordinatorState returns the raw coordinator-state ConfigMap data.
func (c *Cluster) ReadCoordinatorState(ctx context.Context) (map[string]string, error) {
	cm, err := c.Client.GetConfigMap(ctx, c.Namespace, CoordinatorStateMap)
	if err != nil {
		return nil, fmt.Errorf("read coordinator state: %w", err)
	}
	if cm.Data == nil {
		return map[string]string{}, nil
	}
	return cm.Data, nil
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
