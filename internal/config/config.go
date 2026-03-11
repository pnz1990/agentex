// Package config provides configuration management for the agentex coordinator.
// It loads the agentex-constitution ConfigMap and provides typed access to all
// coordinator configuration values.
package config

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
)

// ConstitutionConfigMapName is the name of the god-owned constitution ConfigMap.
const ConstitutionConfigMapName = "agentex-constitution"

// ConstitutionConfig holds typed values from the agentex-constitution ConfigMap.
// These are read-only constants owned by god. Agents (and the coordinator) read
// but never modify them — except through governance vote enactment.
type ConstitutionConfig struct {
	CircuitBreakerLimit    int
	GithubRepo             string
	EcrRegistry            string
	AwsRegion              string
	ClusterName            string
	S3Bucket               string
	Vision                 string
	CivilizationGeneration int
	LastDirective          string
	VoteThreshold          int
	MinimumVisionScore     int
	DailyCostBudgetUSD     int
	AgentModel             string
	JobTTLSeconds          int
	VisionScoreGuidance    string
	SecurityPosture        string
	VisionUnlockGeneration int
}

// Config holds all coordinator configuration, combining command-line flags
// with constitution values loaded from the cluster.
type Config struct {
	// Namespace is the Kubernetes namespace for all agentex resources.
	Namespace string

	// HeartbeatInterval is how often the coordinator writes a heartbeat.
	HeartbeatInterval time.Duration

	// Kubeconfig is the path to a kubeconfig file (empty for in-cluster).
	Kubeconfig string

	// Constitution holds the typed values from the agentex-constitution ConfigMap.
	// Protected by mu for concurrent access during informer-driven updates.
	mu           sync.RWMutex
	Constitution ConstitutionConfig

	logger *slog.Logger
}

// NewConfig creates a Config with the given parameters. Constitution values
// are zero-valued until LoadFromConfigMap is called.
func NewConfig(namespace string, heartbeatInterval time.Duration, kubeconfig string, logger *slog.Logger) *Config {
	return &Config{
		Namespace:         namespace,
		HeartbeatInterval: heartbeatInterval,
		Kubeconfig:        kubeconfig,
		logger:            logger,
	}
}

// GetConstitution returns a snapshot of the current constitution config.
// Thread-safe for concurrent reads during informer updates.
func (c *Config) GetConstitution() ConstitutionConfig {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.Constitution
}

// LoadFromConfigMap reads the agentex-constitution ConfigMap and parses all
// fields into the Constitution struct. Unknown fields are silently ignored.
func (c *Config) LoadFromConfigMap(cm *corev1.ConfigMap) error {
	if cm == nil || cm.Data == nil {
		return fmt.Errorf("constitution ConfigMap is nil or has no data")
	}

	parsed := ConstitutionConfig{
		// Defaults matching the bash coordinator's fallback values
		CircuitBreakerLimit:    6,
		VoteThreshold:          3,
		MinimumVisionScore:     5,
		DailyCostBudgetUSD:     50,
		JobTTLSeconds:          180,
		CivilizationGeneration: 1,
		VisionUnlockGeneration: 10,
	}

	data := cm.Data

	// String fields
	parsed.GithubRepo = getStringOrDefault(data, "githubRepo", "")
	parsed.EcrRegistry = getStringOrDefault(data, "ecrRegistry", "")
	parsed.AwsRegion = getStringOrDefault(data, "awsRegion", "us-west-2")
	parsed.ClusterName = getStringOrDefault(data, "clusterName", "agentex")
	parsed.S3Bucket = getStringOrDefault(data, "s3Bucket", "agentex-thoughts")
	parsed.Vision = getStringOrDefault(data, "vision", "")
	parsed.LastDirective = getStringOrDefault(data, "lastDirective", "")
	parsed.AgentModel = getStringOrDefault(data, "agentModel", "us.anthropic.claude-sonnet-4-6")
	parsed.VisionScoreGuidance = getStringOrDefault(data, "visionScoreGuidance", "")
	parsed.SecurityPosture = getStringOrDefault(data, "securityPosture", "")

	// Integer fields
	parsed.CircuitBreakerLimit = getIntOrDefault(data, "circuitBreakerLimit", parsed.CircuitBreakerLimit)
	parsed.CivilizationGeneration = getIntOrDefault(data, "civilizationGeneration", parsed.CivilizationGeneration)
	parsed.VoteThreshold = getIntOrDefault(data, "voteThreshold", parsed.VoteThreshold)
	parsed.MinimumVisionScore = getIntOrDefault(data, "minimumVisionScore", parsed.MinimumVisionScore)
	parsed.DailyCostBudgetUSD = getIntOrDefault(data, "dailyCostBudgetUSD", parsed.DailyCostBudgetUSD)
	parsed.JobTTLSeconds = getIntOrDefault(data, "jobTTLSeconds", parsed.JobTTLSeconds)
	parsed.VisionUnlockGeneration = getIntOrDefault(data, "visionUnlockGeneration", parsed.VisionUnlockGeneration)

	c.mu.Lock()
	c.Constitution = parsed
	c.mu.Unlock()

	c.logger.Info("loaded constitution",
		"circuitBreakerLimit", parsed.CircuitBreakerLimit,
		"githubRepo", parsed.GithubRepo,
		"voteThreshold", parsed.VoteThreshold,
		"awsRegion", parsed.AwsRegion,
		"civilizationGeneration", parsed.CivilizationGeneration,
	)

	return nil
}

// WatchConstitution starts an informer that watches the constitution ConfigMap
// and automatically updates the Config when it changes. The informer runs until
// ctx is cancelled. This is non-blocking — it starts the informer in a goroutine.
func (c *Config) WatchConstitution(ctx context.Context, clientset kubernetes.Interface) {
	// Create a filtered informer factory that only watches the constitution ConfigMap.
	// This avoids loading all ConfigMaps in the namespace.
	factory := informers.NewSharedInformerFactoryWithOptions(
		clientset,
		60*time.Second, // resync period
		informers.WithNamespace(c.Namespace),
		informers.WithTweakListOptions(func(opts *metav1.ListOptions) {
			opts.FieldSelector = fields.OneTermEqualSelector("metadata.name", ConstitutionConfigMapName).String()
		}),
	)

	informer := factory.Core().V1().ConfigMaps().Informer()
	registration, err := informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		UpdateFunc: func(_, newObj interface{}) {
			cm, ok := newObj.(*corev1.ConfigMap)
			if !ok || cm.Name != ConstitutionConfigMapName {
				return
			}
			c.logger.Info("constitution ConfigMap updated, reloading")
			if err := c.LoadFromConfigMap(cm); err != nil {
				c.logger.Error("failed to reload constitution", "error", err)
			}
		},
	})
	if err != nil {
		c.logger.Error("failed to add constitution watch handler", "error", err)
		return
	}
	_ = registration // informer manages the lifecycle

	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())
	c.logger.Info("constitution watch started")
}

func getStringOrDefault(data map[string]string, key, defaultVal string) string {
	if v, ok := data[key]; ok && v != "" {
		return v
	}
	return defaultVal
}

func getIntOrDefault(data map[string]string, key string, defaultVal int) int {
	v, ok := data[key]
	if !ok || v == "" {
		return defaultVal
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return defaultVal
	}
	return n
}
