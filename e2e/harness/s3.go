//go:build e2e

package harness

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	agentexs3 "github.com/pnz1990/agentex/internal/s3"
)

// S3Client returns an S3 client configured for e2e test isolation.
// It reads S3_BUCKET, E2E_S3_PREFIX, and AWS_REGION from the environment,
// defaulting to "agentex-thoughts", "e2e/", and "us-west-2" respectively.
func (c *Cluster) S3Client() *agentexs3.Client {
	bucket := envOrDefault("S3_BUCKET", "agentex-thoughts")
	prefix := envOrDefault("E2E_S3_PREFIX", "e2e/")
	region := envOrDefault("AWS_REGION", "us-west-2")
	return agentexs3.NewClient(bucket, prefix, region)
}

// AssertS3KeyExists fails if the given S3 key (relative to E2E_S3_PREFIX) does not exist.
func (c *Cluster) AssertS3KeyExists(ctx context.Context, t *testing.T, key string) {
	t.Helper()
	s3c := c.S3Client()
	exists, err := s3c.KeyExists(ctx, key)
	if err != nil {
		t.Errorf("AssertS3KeyExists %s: %v", key, err)
		return
	}
	if !exists {
		t.Errorf("expected S3 key %q to exist, but it does not", key)
	}
}

// AssertS3KeyAbsent fails if the given S3 key (relative to E2E_S3_PREFIX) exists.
func (c *Cluster) AssertS3KeyAbsent(ctx context.Context, t *testing.T, key string) {
	t.Helper()
	s3c := c.S3Client()
	exists, err := s3c.KeyExists(ctx, key)
	if err != nil && !isErrNotExistHelper(err) {
		t.Errorf("AssertS3KeyAbsent %s: %v", key, err)
		return
	}
	if exists {
		t.Errorf("expected S3 key %q to be absent, but it exists", key)
	}
}

// WaitForS3Key polls until the given S3 key exists or timeout is reached.
func (c *Cluster) WaitForS3Key(ctx context.Context, t *testing.T, key string, timeout time.Duration) {
	t.Helper()
	s3c := c.S3Client()
	c.WaitReady(ctx, t, fmt.Sprintf("S3 key %s", key), timeout, func() (bool, error) {
		exists, err := s3c.KeyExists(ctx, key)
		if err != nil && !isErrNotExistHelper(err) {
			return false, err
		}
		return exists, nil
	})
}

// GetS3PlanningState reads and returns the planning state for the given agent.
func (c *Cluster) GetS3PlanningState(ctx context.Context, t *testing.T, agentName string) *agentexs3.S3PlanningState {
	t.Helper()
	s3c := c.S3Client()
	key := fmt.Sprintf("planning/%s.json", agentName)
	var state agentexs3.S3PlanningState
	if err := s3c.GetJSON(ctx, key, &state); err != nil {
		t.Fatalf("get S3 planning state for %s: %v", agentName, err)
	}
	return &state
}

// GetS3Identity reads and returns the identity for the given agent.
func (c *Cluster) GetS3Identity(ctx context.Context, t *testing.T, agentName string) *agentexs3.S3Identity {
	t.Helper()
	s3c := c.S3Client()
	key := fmt.Sprintf("identity/%s.json", agentName)
	var identity agentexs3.S3Identity
	if err := s3c.GetJSON(ctx, key, &identity); err != nil {
		t.Fatalf("get S3 identity for %s: %v", agentName, err)
	}
	return &identity
}

// ListS3SwarmMemories lists swarm memory keys for the given agent.
func (c *Cluster) ListS3SwarmMemories(ctx context.Context, t *testing.T, agentName string) []string {
	t.Helper()
	s3c := c.S3Client()
	prefix := fmt.Sprintf("swarm/%s-", agentName)
	keys, err := s3c.ListKeys(ctx, prefix)
	if err != nil {
		t.Fatalf("list S3 swarm memories for %s: %v", agentName, err)
	}
	return keys
}

// GetS3SharedSwarmMemory reads the shared swarm memory object for the given swarm name.
// The object is written to "swarm-memories/<swarmName>.json" by mock agents that
// have FLIGHT_SWARM_NAME set. Multiple agents in the same swarm append themselves
// to the same object via read-modify-write in s3_behaviors.go.
func (c *Cluster) GetS3SharedSwarmMemory(ctx context.Context, t *testing.T, swarmName string) *agentexs3.S3SwarmMemory {
	t.Helper()
	s3c := c.S3Client()
	key := fmt.Sprintf("swarm-memories/%s.json", swarmName)
	var mem agentexs3.S3SwarmMemory
	if err := s3c.GetJSON(ctx, key, &mem); err != nil {
		t.Fatalf("get S3 shared swarm memory for swarm %s: %v", swarmName, err)
	}
	return &mem
}

// WaitForS3SharedSwarmMemberCount polls until the shared swarm memory for swarmName
// has at least wantCount members, or timeout is reached.
// This is needed because multiple agents write concurrently and there is no
// guaranteed ordering — the test must wait for all 3 agents to finish writing.
func (c *Cluster) WaitForS3SharedSwarmMemberCount(ctx context.Context, t *testing.T, swarmName string, wantCount int, timeout time.Duration) {
	t.Helper()
	s3c := c.S3Client()
	key := fmt.Sprintf("swarm-memories/%s.json", swarmName)
	c.WaitReady(ctx, t, fmt.Sprintf("swarm-memories/%s members >= %d", swarmName, wantCount), timeout, func() (bool, error) {
		var mem agentexs3.S3SwarmMemory
		if err := s3c.GetJSON(ctx, key, &mem); err != nil {
			return false, nil // key may not exist yet — keep polling
		}
		return len(mem.Members) >= wantCount, nil
	})
}

// CleanupS3SharedSwarmMemory deletes the shared swarm memory object for a swarm name.
func (c *Cluster) CleanupS3SharedSwarmMemory(ctx context.Context, t *testing.T, swarmName string) {
	t.Helper()
	if os.Getenv("E2E_S3_CLEANUP") == "false" {
		t.Logf("skipping S3 cleanup (E2E_S3_CLEANUP=false)")
		return
	}
	s3c := c.S3Client()
	key := fmt.Sprintf("swarm-memories/%s.json", swarmName)
	if err := s3c.DeletePrefix(ctx, key); err != nil {
		t.Logf("S3 cleanup swarm-memories/%s: %v", swarmName, err)
	}
}

// ListS3ChronicleCandidates lists chronicle candidate keys for the given agent.
func (c *Cluster) ListS3ChronicleCandidates(ctx context.Context, t *testing.T, agentName string) []string {
	t.Helper()
	s3c := c.S3Client()
	prefix := fmt.Sprintf("chronicle-candidates/%s-", agentName)
	keys, err := s3c.ListKeys(ctx, prefix)
	if err != nil {
		t.Fatalf("list S3 chronicle candidates for %s: %v", agentName, err)
	}
	return keys
}

// CleanupE2ES3Prefix deletes all S3 objects under the E2E_S3_PREFIX for a given agent.
// This should be called in test cleanup to keep S3 clean between runs.
func (c *Cluster) CleanupE2ES3Prefix(ctx context.Context, t *testing.T, agentName string) {
	t.Helper()

	if os.Getenv("E2E_S3_CLEANUP") == "false" {
		t.Logf("skipping S3 cleanup (E2E_S3_CLEANUP=false)")
		return
	}

	s3c := c.S3Client()
	// Delete agent-specific prefixes
	prefixes := []string{
		fmt.Sprintf("planning/%s.json", agentName),
		fmt.Sprintf("identity/%s.json", agentName),
		fmt.Sprintf("swarm/%s-", agentName),
		fmt.Sprintf("chronicle-candidates/%s-", agentName),
	}

	for _, prefix := range prefixes {
		if err := s3c.DeletePrefix(ctx, prefix); err != nil {
			t.Logf("S3 cleanup %s: %v", prefix, err)
		}
	}
}

func isErrNotExistHelper(err error) bool {
	return err != nil && os.IsNotExist(err)
}
