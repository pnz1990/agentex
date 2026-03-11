package agent

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	k8sfake "k8s.io/client-go/kubernetes/fake"

	"github.com/pnz1990/agentex/internal/k8s"
)

// newBehaviorTestClient creates a k8s.Client with fake clients that include
// Thought and Message GVRs in the dynamic scheme.
func newBehaviorTestClient(t *testing.T) *k8s.Client {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	clientset := k8sfake.NewSimpleClientset()

	scheme := runtime.NewScheme()
	dynClient := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{
			k8s.ThoughtGVR: "ThoughtList",
			k8s.MessageGVR: "MessageList",
			k8s.ReportGVR:  "ReportList",
		},
	)
	return k8s.NewClientFromInterfaces(clientset, dynClient, logger)
}

// --- LoadFlightBehaviorConfig ---

func TestLoadFlightBehaviorConfig_Defaults(t *testing.T) {
	// Clear any env vars that might be set in test environment.
	os.Unsetenv("FLIGHT_THOUGHT_COUNT")
	os.Unsetenv("FLIGHT_DEBATE_ENABLED")
	os.Unsetenv("FLIGHT_MESSAGE_ENABLED")
	os.Unsetenv("FLIGHT_MESSAGE_TARGET")

	cfg := LoadFlightBehaviorConfig()

	if cfg.ThoughtCount != 2 {
		t.Errorf("ThoughtCount = %d, want 2", cfg.ThoughtCount)
	}
	if cfg.DebateEnabled {
		t.Error("DebateEnabled = true, want false")
	}
	if cfg.MessageEnabled {
		t.Error("MessageEnabled = true, want false")
	}
	if cfg.MessageTarget != "broadcast" {
		t.Errorf("MessageTarget = %q, want broadcast", cfg.MessageTarget)
	}
}

func TestLoadFlightBehaviorConfig_FromEnv(t *testing.T) {
	t.Setenv("FLIGHT_THOUGHT_COUNT", "4")
	t.Setenv("FLIGHT_DEBATE_ENABLED", "true")
	t.Setenv("FLIGHT_MESSAGE_ENABLED", "true")
	t.Setenv("FLIGHT_MESSAGE_TARGET", "coordinator-agent")

	cfg := LoadFlightBehaviorConfig()

	if cfg.ThoughtCount != 4 {
		t.Errorf("ThoughtCount = %d, want 4", cfg.ThoughtCount)
	}
	if !cfg.DebateEnabled {
		t.Error("DebateEnabled = false, want true")
	}
	if !cfg.MessageEnabled {
		t.Error("MessageEnabled = false, want true")
	}
	if cfg.MessageTarget != "coordinator-agent" {
		t.Errorf("MessageTarget = %q, want coordinator-agent", cfg.MessageTarget)
	}
}

func TestLoadFlightBehaviorConfig_ZeroThoughts(t *testing.T) {
	t.Setenv("FLIGHT_THOUGHT_COUNT", "0")
	cfg := LoadFlightBehaviorConfig()
	if cfg.ThoughtCount != 0 {
		t.Errorf("ThoughtCount = %d, want 0", cfg.ThoughtCount)
	}
}

func TestLoadFlightBehaviorConfig_InvalidThoughtCount(t *testing.T) {
	t.Setenv("FLIGHT_THOUGHT_COUNT", "notanumber")
	cfg := LoadFlightBehaviorConfig()
	// Falls back to default.
	if cfg.ThoughtCount != 2 {
		t.Errorf("ThoughtCount = %d, want 2 (default after invalid input)", cfg.ThoughtCount)
	}
}

// --- PostThought ---

func TestPostThought_Success(t *testing.T) {
	client := newBehaviorTestClient(t)
	ctx := context.Background()

	err := PostThought(ctx, client, "agentex", "test-agent", "task-123", "insight", "flight test insight content")
	if err != nil {
		t.Fatalf("PostThought returned error: %v", err)
	}

	// Verify the CR was created in the fake client.
	list, err := client.ListCRs(ctx, "agentex", k8s.ThoughtGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("listing thought CRs: %v", err)
	}
	if len(list.Items) != 1 {
		t.Fatalf("expected 1 thought CR, got %d", len(list.Items))
	}

	obj := list.Items[0]
	spec, _ := obj.Object["spec"].(map[string]interface{})
	if spec["agentRef"] != "test-agent" {
		t.Errorf("agentRef = %v, want test-agent", spec["agentRef"])
	}
	if spec["thoughtType"] != "insight" {
		t.Errorf("thoughtType = %v, want insight", spec["thoughtType"])
	}
	if spec["content"] != "flight test insight content" {
		t.Errorf("content = %v, want 'flight test insight content'", spec["content"])
	}
	if spec["topic"] != "flight-test" {
		t.Errorf("topic = %v, want flight-test", spec["topic"])
	}

	// Name should start with "thought-test-agent-".
	name := obj.GetName()
	if !strings.HasPrefix(name, "thought-test-agent-insight-") {
		t.Errorf("name = %q, want prefix 'thought-test-agent-insight-'", name)
	}

	// Labels
	labels := obj.GetLabels()
	if labels["agentex/agent"] != "test-agent" {
		t.Errorf("label agentex/agent = %q, want test-agent", labels["agentex/agent"])
	}
	if labels["agentex/e2e"] != "true" {
		t.Errorf("label agentex/e2e = %q, want true", labels["agentex/e2e"])
	}
}

// --- PostMessage ---

func TestPostMessage_Success(t *testing.T) {
	client := newBehaviorTestClient(t)
	ctx := context.Background()

	err := PostMessage(ctx, client, "agentex", "sender-agent", "broadcast", "hello from flight test")
	if err != nil {
		t.Fatalf("PostMessage returned error: %v", err)
	}

	list, err := client.ListCRs(ctx, "agentex", k8s.MessageGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("listing message CRs: %v", err)
	}
	if len(list.Items) != 1 {
		t.Fatalf("expected 1 message CR, got %d", len(list.Items))
	}

	obj := list.Items[0]
	spec, _ := obj.Object["spec"].(map[string]interface{})
	if spec["from"] != "sender-agent" {
		t.Errorf("from = %v, want sender-agent", spec["from"])
	}
	if spec["to"] != "broadcast" {
		t.Errorf("to = %v, want broadcast", spec["to"])
	}
	if spec["body"] != "hello from flight test" {
		t.Errorf("body = %v, want 'hello from flight test'", spec["body"])
	}
	if spec["messageType"] != "status" {
		t.Errorf("messageType = %v, want status", spec["messageType"])
	}
}

func TestPostMessage_DirectTarget(t *testing.T) {
	client := newBehaviorTestClient(t)
	ctx := context.Background()

	err := PostMessage(ctx, client, "agentex", "worker-1", "reviewer-1", "PR ready for review")
	if err != nil {
		t.Fatalf("PostMessage returned error: %v", err)
	}

	list, _ := client.ListCRs(ctx, "agentex", k8s.MessageGVR, metav1.ListOptions{})
	obj := list.Items[0]
	labels := obj.GetLabels()
	if labels["agentex/to"] != "reviewer-1" {
		t.Errorf("label agentex/to = %q, want reviewer-1", labels["agentex/to"])
	}
}

// --- RunFlightBehaviors ---

func TestRunFlightBehaviors_TwoThoughts(t *testing.T) {
	client := newBehaviorTestClient(t)
	ctx := context.Background()

	agentCfg := &AgentConfig{
		Name:       "flight-agent-1",
		Role:       "worker",
		TaskCRName: "task-flight-1",
		Namespace:  "agentex",
	}
	behaviorCfg := &FlightBehaviorConfig{
		ThoughtCount:   2,
		DebateEnabled:  false,
		MessageEnabled: false,
	}
	task := &TaskInfo{IssueNumber: 42, Title: "Fix the widget"}

	RunFlightBehaviors(ctx, client, agentCfg, behaviorCfg, task)

	thoughts, err := client.ListCRs(ctx, "agentex", k8s.ThoughtGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("listing thoughts: %v", err)
	}
	if len(thoughts.Items) != 2 {
		t.Errorf("got %d thought CRs, want 2", len(thoughts.Items))
	}
	messages, _ := client.ListCRs(ctx, "agentex", k8s.MessageGVR, metav1.ListOptions{})
	if len(messages.Items) != 0 {
		t.Errorf("got %d message CRs, want 0 (MessageEnabled=false)", len(messages.Items))
	}
}

func TestRunFlightBehaviors_DebateAndMessage(t *testing.T) {
	client := newBehaviorTestClient(t)
	ctx := context.Background()

	agentCfg := &AgentConfig{
		Name:       "flight-agent-2",
		Role:       "worker",
		TaskCRName: "task-flight-2",
		Namespace:  "agentex",
	}
	behaviorCfg := &FlightBehaviorConfig{
		ThoughtCount:   1,
		DebateEnabled:  true,
		MessageEnabled: true,
		MessageTarget:  "broadcast",
	}
	task := &TaskInfo{IssueNumber: 99, Title: "Add feature X"}

	RunFlightBehaviors(ctx, client, agentCfg, behaviorCfg, task)

	// 1 regular thought + 1 debate vote thought = 2 total
	thoughts, _ := client.ListCRs(ctx, "agentex", k8s.ThoughtGVR, metav1.ListOptions{})
	if len(thoughts.Items) != 2 {
		t.Errorf("got %d thought CRs, want 2 (1 insight + 1 debate vote)", len(thoughts.Items))
	}

	// Check the vote thought exists.
	hasVote := false
	for _, th := range thoughts.Items {
		spec, _ := th.Object["spec"].(map[string]interface{})
		if spec["thoughtType"] == "vote" {
			hasVote = true
		}
	}
	if !hasVote {
		t.Error("expected a vote-type thought for debate, none found")
	}

	messages, _ := client.ListCRs(ctx, "agentex", k8s.MessageGVR, metav1.ListOptions{})
	if len(messages.Items) != 1 {
		t.Errorf("got %d message CRs, want 1", len(messages.Items))
	}
}

func TestRunFlightBehaviors_ZeroThoughts(t *testing.T) {
	client := newBehaviorTestClient(t)
	ctx := context.Background()

	agentCfg := &AgentConfig{
		Name: "silent-agent", Role: "worker",
		TaskCRName: "task-silent", Namespace: "agentex",
	}
	behaviorCfg := &FlightBehaviorConfig{ThoughtCount: 0}
	task := &TaskInfo{IssueNumber: 1, Title: "Noop"}

	RunFlightBehaviors(ctx, client, agentCfg, behaviorCfg, task)

	thoughts, _ := client.ListCRs(ctx, "agentex", k8s.ThoughtGVR, metav1.ListOptions{})
	if len(thoughts.Items) != 0 {
		t.Errorf("got %d thought CRs, want 0", len(thoughts.Items))
	}
}

// --- flightThoughtContent ---

func TestFlightThoughtContent_Varies(t *testing.T) {
	task := &TaskInfo{IssueNumber: 7, Title: "Refactor coordinator"}

	c0 := flightThoughtContent("a1", "worker", task, 0, "insight")
	c1 := flightThoughtContent("a1", "worker", task, 1, "observation")

	if c0 == c1 {
		t.Error("expected different content at index 0 vs 1")
	}

	// Both should mention the agent name and issue number.
	for i, c := range []string{c0, c1} {
		if !strings.Contains(c, "a1") {
			t.Errorf("content[%d] missing agent name: %q", i, c)
		}
		if !strings.Contains(c, "7") {
			t.Errorf("content[%d] missing issue number: %q", i, c)
		}
	}
}
