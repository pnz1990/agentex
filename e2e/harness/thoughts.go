//go:build e2e

package harness

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/pnz1990/agentex/internal/k8s"
)

// ListThoughtCRs returns all Thought CRs in the namespace.
func (c *Cluster) ListThoughtCRs(ctx context.Context, t *testing.T) []unstructured.Unstructured {
	t.Helper()
	list, err := c.Client.ListCRs(ctx, c.Namespace, k8s.ThoughtGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("list thought CRs: %v", err)
	}
	return list.Items
}

// ListThoughtCRsByAgent returns all Thought CRs posted by the given agent.
func (c *Cluster) ListThoughtCRsByAgent(ctx context.Context, t *testing.T, agentName string) []unstructured.Unstructured {
	t.Helper()
	list, err := c.Client.ListCRs(ctx, c.Namespace, k8s.ThoughtGVR,
		metav1.ListOptions{LabelSelector: "agentex/agent=" + agentName})
	if err != nil {
		t.Fatalf("list thought CRs for agent %s: %v", agentName, err)
	}
	return list.Items
}

// ListMessageCRs returns all Message CRs in the namespace.
func (c *Cluster) ListMessageCRs(ctx context.Context, t *testing.T) []unstructured.Unstructured {
	t.Helper()
	list, err := c.Client.ListCRs(ctx, c.Namespace, k8s.MessageGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("list message CRs: %v", err)
	}
	return list.Items
}

// WaitForThoughtCRs polls until at least minCount Thought CRs from the given agent exist.
func (c *Cluster) WaitForThoughtCRs(ctx context.Context, t *testing.T, agentName string, minCount int, timeout time.Duration) {
	t.Helper()
	c.WaitReady(ctx, t,
		fmt.Sprintf("at least %d thought CRs from %s", minCount, agentName),
		timeout,
		func() (bool, error) {
			thoughts := c.ListThoughtCRsByAgent(ctx, t, agentName)
			return len(thoughts) >= minCount, nil
		},
	)
}

// WaitForMessageCR polls until at least one Message CR from the given agent exists.
func (c *Cluster) WaitForMessageCR(ctx context.Context, t *testing.T, fromAgent string, timeout time.Duration) {
	t.Helper()
	c.WaitReady(ctx, t,
		fmt.Sprintf("message CR from %s", fromAgent),
		timeout,
		func() (bool, error) {
			msgs := c.ListMessageCRs(ctx, t)
			for _, m := range msgs {
				if m.GetLabels()["agentex/from"] == fromAgent {
					return true, nil
				}
			}
			return false, nil
		},
	)
}

// AssertThoughtCRPosted fails if no Thought CR from agentName exists.
func (c *Cluster) AssertThoughtCRPosted(ctx context.Context, t *testing.T, agentName string) {
	t.Helper()
	thoughts := c.ListThoughtCRsByAgent(ctx, t, agentName)
	if len(thoughts) == 0 {
		t.Errorf("no Thought CRs found for agent %q", agentName)
	}
}

// AssertThoughtCRCount fails if the number of Thought CRs from agentName is not exactly n.
func (c *Cluster) AssertThoughtCRCount(ctx context.Context, t *testing.T, agentName string, n int) {
	t.Helper()
	thoughts := c.ListThoughtCRsByAgent(ctx, t, agentName)
	if len(thoughts) != n {
		t.Errorf("expected %d thought CRs from %s, got %d", n, agentName, len(thoughts))
	}
}

// AssertThoughtCRTypes fails if the Thought CRs from agentName don't include all wantTypes.
func (c *Cluster) AssertThoughtCRTypes(ctx context.Context, t *testing.T, agentName string, wantTypes ...string) {
	t.Helper()
	thoughts := c.ListThoughtCRsByAgent(ctx, t, agentName)

	found := make(map[string]bool)
	for _, th := range thoughts {
		spec, _ := th.Object["spec"].(map[string]interface{})
		if spec != nil {
			if tt, ok := spec["thoughtType"].(string); ok {
				found[tt] = true
			}
		}
		// Also check the label
		if tt := th.GetLabels()["agentex/type"]; tt != "" {
			found[tt] = true
		}
	}

	for _, want := range wantTypes {
		if !found[want] {
			var got []string
			for k := range found {
				got = append(got, k)
			}
			t.Errorf("expected thought type %q from agent %s, got types: %v", want, agentName, got)
		}
	}
}

// AssertThoughtContentContains fails if no Thought CR from agentName has content containing substr.
func (c *Cluster) AssertThoughtContentContains(ctx context.Context, t *testing.T, agentName, substr string) {
	t.Helper()
	thoughts := c.ListThoughtCRsByAgent(ctx, t, agentName)
	for _, th := range thoughts {
		spec, _ := th.Object["spec"].(map[string]interface{})
		if spec != nil {
			content, _ := spec["content"].(string)
			if strings.Contains(content, substr) {
				return
			}
		}
	}
	t.Errorf("no Thought CR from %s contains %q", agentName, substr)
}

// AssertMessageCRPosted fails if no Message CR from the given agent exists.
func (c *Cluster) AssertMessageCRPosted(ctx context.Context, t *testing.T, fromAgent string) {
	t.Helper()
	msgs := c.ListMessageCRs(ctx, t)
	for _, m := range msgs {
		if m.GetLabels()["agentex/from"] == fromAgent {
			return
		}
	}
	t.Errorf("no Message CR found from agent %q", fromAgent)
}

// AssertDebateThought fails if no Thought CR of type "vote" from agentName exists.
func (c *Cluster) AssertDebateThought(ctx context.Context, t *testing.T, agentName string) {
	t.Helper()
	thoughts := c.ListThoughtCRsByAgent(ctx, t, agentName)
	for _, th := range thoughts {
		if th.GetLabels()["agentex/type"] == "vote" {
			return
		}
		spec, _ := th.Object["spec"].(map[string]interface{})
		if spec != nil {
			if tt, _ := spec["thoughtType"].(string); tt == "vote" {
				return
			}
		}
	}
	t.Errorf("no debate (vote) Thought CR found for agent %q", agentName)
}

// DeleteThoughtCRsForAgent deletes all Thought CRs from a given agent (used in teardown).
func (c *Cluster) DeleteThoughtCRsForAgent(ctx context.Context, t *testing.T, agentName string) {
	t.Helper()
	thoughts := c.ListThoughtCRsByAgent(ctx, t, agentName)
	for _, th := range thoughts {
		if err := c.Client.DeleteCR(ctx, c.Namespace, k8s.ThoughtGVR, th.GetName()); err != nil {
			t.Logf("delete thought CR %s: %v", th.GetName(), err)
		}
	}
}

// DeleteAllThoughtCRs deletes all Thought CRs labeled agentex/flight=true (e2e cleanup).
func (c *Cluster) DeleteAllThoughtCRs(ctx context.Context, t *testing.T) {
	t.Helper()
	list, err := c.Client.ListCRs(ctx, c.Namespace, k8s.ThoughtGVR,
		metav1.ListOptions{LabelSelector: "agentex/flight=true"})
	if err != nil {
		t.Logf("list thought CRs for cleanup: %v", err)
		return
	}
	for _, th := range list.Items {
		if err := c.Client.DeleteCR(ctx, c.Namespace, k8s.ThoughtGVR, th.GetName()); err != nil {
			t.Logf("delete thought CR %s: %v", th.GetName(), err)
		}
	}
}

// DeleteAllMessageCRs deletes all Message CRs labeled agentex/flight=true (e2e cleanup).
func (c *Cluster) DeleteAllMessageCRs(ctx context.Context, t *testing.T) {
	t.Helper()
	list, err := c.Client.ListCRs(ctx, c.Namespace, k8s.MessageGVR,
		metav1.ListOptions{LabelSelector: "agentex/flight=true"})
	if err != nil {
		t.Logf("list message CRs for cleanup: %v", err)
		return
	}
	for _, m := range list.Items {
		if err := c.Client.DeleteCR(ctx, c.Namespace, k8s.MessageGVR, m.GetName()); err != nil {
			t.Logf("delete message CR %s: %v", m.GetName(), err)
		}
	}
}
