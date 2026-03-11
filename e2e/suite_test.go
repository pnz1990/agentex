//go:build e2e

// Package e2e contains end-to-end flight tests for the agentex platform.
//
// These tests run against a real Kubernetes cluster (kind + kro) and use
// mock agents (AGENTEX_FLIGHT_TEST=true) to exercise the full coordinator
// lifecycle without real OpenCode/Bedrock sessions.
//
// Run with:
//
//	go test -v -tags e2e -timeout 20m ./e2e/... -run TestBasicDispatch
//
// Required environment variables:
//
//	KUBECONFIG          - path to kubeconfig (uses in-cluster if absent)
//	FLIGHT_TEST_IMAGE   - image with /agent/agent binary (default: agentex/runner:latest)
//	E2E_NAMESPACE       - namespace to use (default: agentex-e2e)
package e2e

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/pnz1990/agentex/e2e/harness"
)

// TestMain runs the full test suite. It sets up a fresh namespace, applies
// fixtures, and tears down after all tests complete.
func TestMain(m *testing.M) {
	// TestMain cannot use *testing.T, so we use os.Exit directly.
	// Each individual test calls harness.New(t) and manages its own lifecycle.
	code := m.Run()
	os.Exit(code)
}

// newCluster is a helper that creates and sets up a harness.Cluster for a test.
// The cluster's namespace is torn down via t.Cleanup.
func newCluster(t *testing.T) (*harness.Cluster, context.Context) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	t.Cleanup(cancel)

	c := harness.New(t)
	c.Setup(ctx, t)
	t.Cleanup(func() {
		// Use a fresh context for teardown so it isn't affected by test timeout.
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cleanupCancel()
		c.Teardown(cleanupCtx, t)
	})
	return c, ctx
}
