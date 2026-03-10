// Package config handles reading coordinator configuration from Kubernetes
// ConfigMaps and environment variables.
//
// The coordinator reads its configuration from:
//   1. The agentex-constitution ConfigMap (canonical source of truth)
//   2. Environment variables (fallback / override)
//   3. The agentex-killswitch ConfigMap (kill switch state)
package config

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// Config holds all coordinator configuration.
// Values are refreshed from the constitution ConfigMap every RefreshInterval.
type Config struct {
	// From agentex-constitution ConfigMap
	Namespace           string
	GitHubRepo          string
	ECRRegistry         string
	AWSRegion           string
	ClusterName         string
	S3Bucket            string
	CircuitBreakerLimit int
	BedrockModel        string

	// Kill switch state
	KillSwitchEnabled bool
	KillSwitchReason  string

	// Coordinator-specific settings
	VoteThreshold      int
	HeartbeatInterval  time.Duration
	StaleAssignTimeout time.Duration
	TaskRefreshInterval time.Duration
	DBPath             string
	ListenAddr         string

	mu        sync.RWMutex
	k8s       kubernetes.Interface
	lastFetch time.Time
}

// Default values used when ConfigMap entries are missing.
const (
	DefaultNamespace           = "agentex"
	DefaultCircuitBreakerLimit = 10
	DefaultVoteThreshold       = 3
	DefaultHeartbeatInterval   = 30 * time.Second
	DefaultStaleAssignTimeout  = 5 * time.Minute
	DefaultTaskRefreshInterval = 2*time.Minute + 30*time.Second
	DefaultDBPath              = "/data/coordinator.db"
	DefaultListenAddr          = ":8080"
)

// New creates a Config populated from environment variables and defaults.
// Call Refresh() to load live values from Kubernetes ConfigMaps.
func New(k8s kubernetes.Interface) *Config {
	c := &Config{
		k8s:                 k8s,
		Namespace:           env("NAMESPACE", DefaultNamespace),
		GitHubRepo:          env("REPO", "pnz1990/agentex"),
		AWSRegion:           env("BEDROCK_REGION", "us-west-2"),
		ClusterName:         env("CLUSTER", "agentex"),
		S3Bucket:            env("S3_BUCKET", "agentex-thoughts"),
		CircuitBreakerLimit: envInt("CIRCUIT_BREAKER_LIMIT", DefaultCircuitBreakerLimit),
		BedrockModel:        env("BEDROCK_MODEL", "us.anthropic.claude-sonnet-4-6"),
		VoteThreshold:       DefaultVoteThreshold,
		HeartbeatInterval:   DefaultHeartbeatInterval,
		StaleAssignTimeout:  DefaultStaleAssignTimeout,
		TaskRefreshInterval: DefaultTaskRefreshInterval,
		DBPath:              env("DB_PATH", DefaultDBPath),
		ListenAddr:          env("LISTEN_ADDR", DefaultListenAddr),
	}
	return c
}

// Refresh reads current values from Kubernetes ConfigMaps.
// It is safe to call concurrently — it holds a write lock for the duration.
func (c *Config) Refresh(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Read agentex-constitution
	constitution, err := c.k8s.CoreV1().ConfigMaps(c.Namespace).Get(
		ctx, "agentex-constitution", metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("get constitution: %w", err)
	}

	d := constitution.Data
	if v := d["githubRepo"]; v != "" {
		c.GitHubRepo = v
	}
	if v := d["ecrRegistry"]; v != "" {
		c.ECRRegistry = v
	}
	if v := d["awsRegion"]; v != "" {
		c.AWSRegion = v
	}
	if v := d["clusterName"]; v != "" {
		c.ClusterName = v
	}
	if v := d["s3Bucket"]; v != "" {
		c.S3Bucket = v
	}
	if v := d["circuitBreakerLimit"]; v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			c.CircuitBreakerLimit = n
		}
	}
	if v := d["bedrockModel"]; v != "" {
		c.BedrockModel = v
	}

	// Read agentex-killswitch
	ks, err := c.k8s.CoreV1().ConfigMaps(c.Namespace).Get(
		ctx, "agentex-killswitch", metav1.GetOptions{})
	if err == nil {
		c.KillSwitchEnabled = ks.Data["enabled"] == "true"
		c.KillSwitchReason = ks.Data["reason"]
	} else {
		// Kill switch ConfigMap may not exist — fail closed (safe default: not enabled)
		c.KillSwitchEnabled = false
	}

	c.lastFetch = time.Now()
	return nil
}

// CircuitBreakerOpen returns true if the kill switch is active OR if the
// number of active agents meets/exceeds the circuit breaker limit.
func (c *Config) CircuitBreakerOpen(activeCount int) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.KillSwitchEnabled || activeCount >= c.CircuitBreakerLimit
}

// Snapshot returns a copy of the current configuration values.
// Use this to read multiple fields atomically.
func (c *Config) Snapshot() Config {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return Config{
		Namespace:           c.Namespace,
		GitHubRepo:          c.GitHubRepo,
		ECRRegistry:         c.ECRRegistry,
		AWSRegion:           c.AWSRegion,
		ClusterName:         c.ClusterName,
		S3Bucket:            c.S3Bucket,
		CircuitBreakerLimit: c.CircuitBreakerLimit,
		BedrockModel:        c.BedrockModel,
		KillSwitchEnabled:   c.KillSwitchEnabled,
		KillSwitchReason:    c.KillSwitchReason,
		VoteThreshold:       c.VoteThreshold,
		HeartbeatInterval:   c.HeartbeatInterval,
		StaleAssignTimeout:  c.StaleAssignTimeout,
		TaskRefreshInterval: c.TaskRefreshInterval,
		DBPath:              c.DBPath,
		ListenAddr:          c.ListenAddr,
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}
