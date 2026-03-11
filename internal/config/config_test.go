package config

import (
	"log/slog"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestLoadFromConfigMap(t *testing.T) {
	logger := slog.Default()
	cfg := NewConfig("agentex", 30*time.Second, "", logger)

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ConstitutionConfigMapName,
			Namespace: "agentex",
		},
		Data: map[string]string{
			"circuitBreakerLimit":    "10",
			"githubRepo":             "pnz1990/agentex",
			"ecrRegistry":            "569190534191.dkr.ecr.us-west-2.amazonaws.com",
			"awsRegion":              "us-west-2",
			"clusterName":            "agentex",
			"s3Bucket":               "agentex-thoughts",
			"vision":                 "Agents that propose, vote, debate...",
			"civilizationGeneration": "4",
			"lastDirective":          "Generation 3 ACTIVE.",
			"voteThreshold":          "3",
			"minimumVisionScore":     "3",
			"dailyCostBudgetUSD":     "50",
			"agentModel":             "us.anthropic.claude-sonnet-4-6",
			"jobTTLSeconds":          "180",
			"visionUnlockGeneration": "10",
		},
	}

	err := cfg.LoadFromConfigMap(cm)
	if err != nil {
		t.Fatalf("LoadFromConfigMap: %v", err)
	}

	c := cfg.GetConstitution()

	if c.CircuitBreakerLimit != 10 {
		t.Errorf("CircuitBreakerLimit = %d, want 10", c.CircuitBreakerLimit)
	}
	if c.GithubRepo != "pnz1990/agentex" {
		t.Errorf("GithubRepo = %q, want %q", c.GithubRepo, "pnz1990/agentex")
	}
	if c.EcrRegistry != "569190534191.dkr.ecr.us-west-2.amazonaws.com" {
		t.Errorf("EcrRegistry = %q", c.EcrRegistry)
	}
	if c.AwsRegion != "us-west-2" {
		t.Errorf("AwsRegion = %q, want %q", c.AwsRegion, "us-west-2")
	}
	if c.ClusterName != "agentex" {
		t.Errorf("ClusterName = %q, want %q", c.ClusterName, "agentex")
	}
	if c.S3Bucket != "agentex-thoughts" {
		t.Errorf("S3Bucket = %q", c.S3Bucket)
	}
	if c.CivilizationGeneration != 4 {
		t.Errorf("CivilizationGeneration = %d, want 4", c.CivilizationGeneration)
	}
	if c.VoteThreshold != 3 {
		t.Errorf("VoteThreshold = %d, want 3", c.VoteThreshold)
	}
	if c.MinimumVisionScore != 3 {
		t.Errorf("MinimumVisionScore = %d, want 3", c.MinimumVisionScore)
	}
	if c.VisionUnlockGeneration != 10 {
		t.Errorf("VisionUnlockGeneration = %d, want 10", c.VisionUnlockGeneration)
	}
	if c.LastDirective != "Generation 3 ACTIVE." {
		t.Errorf("LastDirective = %q", c.LastDirective)
	}
}

func TestLoadFromConfigMapDefaults(t *testing.T) {
	logger := slog.Default()
	cfg := NewConfig("agentex", 30*time.Second, "", logger)

	// Minimal ConfigMap — missing most fields, should use defaults
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ConstitutionConfigMapName,
			Namespace: "agentex",
		},
		Data: map[string]string{
			"githubRepo": "myorg/myrepo",
		},
	}

	err := cfg.LoadFromConfigMap(cm)
	if err != nil {
		t.Fatalf("LoadFromConfigMap: %v", err)
	}

	c := cfg.GetConstitution()

	if c.CircuitBreakerLimit != 6 {
		t.Errorf("CircuitBreakerLimit = %d, want default 6", c.CircuitBreakerLimit)
	}
	if c.VoteThreshold != 3 {
		t.Errorf("VoteThreshold = %d, want default 3", c.VoteThreshold)
	}
	if c.MinimumVisionScore != 5 {
		t.Errorf("MinimumVisionScore = %d, want default 5", c.MinimumVisionScore)
	}
	if c.AwsRegion != "us-west-2" {
		t.Errorf("AwsRegion = %q, want default %q", c.AwsRegion, "us-west-2")
	}
	if c.GithubRepo != "myorg/myrepo" {
		t.Errorf("GithubRepo = %q, want %q", c.GithubRepo, "myorg/myrepo")
	}
}

func TestLoadFromConfigMapInvalidIntegers(t *testing.T) {
	logger := slog.Default()
	cfg := NewConfig("agentex", 30*time.Second, "", logger)

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ConstitutionConfigMapName,
			Namespace: "agentex",
		},
		Data: map[string]string{
			"circuitBreakerLimit": "not-a-number",
			"voteThreshold":       "-1",
			"githubRepo":          "test/repo",
		},
	}

	err := cfg.LoadFromConfigMap(cm)
	if err != nil {
		t.Fatalf("LoadFromConfigMap: %v", err)
	}

	c := cfg.GetConstitution()

	// "not-a-number" should fall back to default
	if c.CircuitBreakerLimit != 6 {
		t.Errorf("CircuitBreakerLimit = %d, want default 6 for invalid input", c.CircuitBreakerLimit)
	}
	// "-1" is a valid integer but still parses correctly with Atoi
	if c.VoteThreshold != -1 {
		t.Errorf("VoteThreshold = %d, want -1", c.VoteThreshold)
	}
}

func TestLoadFromConfigMapNilData(t *testing.T) {
	logger := slog.Default()
	cfg := NewConfig("agentex", 30*time.Second, "", logger)

	err := cfg.LoadFromConfigMap(nil)
	if err == nil {
		t.Fatal("expected error for nil ConfigMap")
	}

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "test"},
	}
	err = cfg.LoadFromConfigMap(cm)
	if err == nil {
		t.Fatal("expected error for nil Data")
	}
}

func TestGetConstitutionConcurrency(t *testing.T) {
	logger := slog.Default()
	cfg := NewConfig("agentex", 30*time.Second, "", logger)

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: ConstitutionConfigMapName, Namespace: "agentex"},
		Data: map[string]string{
			"circuitBreakerLimit": "10",
			"githubRepo":          "test/repo",
		},
	}
	if err := cfg.LoadFromConfigMap(cm); err != nil {
		t.Fatal(err)
	}

	// Concurrent reads should not race
	done := make(chan struct{})
	for range 100 {
		go func() {
			c := cfg.GetConstitution()
			if c.CircuitBreakerLimit != 10 {
				t.Errorf("unexpected value during concurrent read: %d", c.CircuitBreakerLimit)
			}
			done <- struct{}{}
		}()
	}
	for range 100 {
		<-done
	}
}

func TestNewConfig(t *testing.T) {
	logger := slog.Default()
	cfg := NewConfig("test-ns", 15*time.Second, "/path/to/kubeconfig", logger)

	if cfg.Namespace != "test-ns" {
		t.Errorf("Namespace = %q, want %q", cfg.Namespace, "test-ns")
	}
	if cfg.HeartbeatInterval != 15*time.Second {
		t.Errorf("HeartbeatInterval = %v, want %v", cfg.HeartbeatInterval, 15*time.Second)
	}
	if cfg.Kubeconfig != "/path/to/kubeconfig" {
		t.Errorf("Kubeconfig = %q, want %q", cfg.Kubeconfig, "/path/to/kubeconfig")
	}
}
