package agent

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	k8sfake "k8s.io/client-go/kubernetes/fake"

	"github.com/pnz1990/agentex/internal/k8s"
	"github.com/pnz1990/agentex/internal/roles"
)

// newTestClient creates a k8s.Client backed by fake clients with optional
// pre-existing unstructured objects.
func newTestClient(t *testing.T, objects ...runtime.Object) *k8s.Client {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	clientset := k8sfake.NewSimpleClientset()

	scheme := runtime.NewScheme()
	dynClient := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{
			k8s.TaskGVR:   "TaskList",
			k8s.ReportGVR: "ReportList",
			k8s.AgentGVR:  "AgentList",
		},
		objects...,
	)

	return k8s.NewClientFromInterfaces(clientset, dynClient, logger)
}

func makeTaskCR(name, namespace string, issueNumber int, title, desc, effort string) *unstructured.Unstructured {
	return &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8s.KroGroup + "/" + k8s.KroVersion,
			"kind":       "Task",
			"metadata": map[string]interface{}{
				"name":      name,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"issueNumber": int64(issueNumber),
				"title":       title,
				"description": desc,
				"effort":      effort,
			},
		},
	}
}

// --- TestReadTask ---

func TestReadTask_Valid(t *testing.T) {
	taskCR := makeTaskCR("task-test-1", "agentex", 42, "Fix the widget", "Widget is broken", "M")
	client := newTestClient(t, taskCR)

	info, err := ReadTask(context.Background(), client, "agentex", "task-test-1")
	if err != nil {
		t.Fatalf("ReadTask returned error: %v", err)
	}
	if info.IssueNumber != 42 {
		t.Errorf("IssueNumber = %d, want 42", info.IssueNumber)
	}
	if info.Title != "Fix the widget" {
		t.Errorf("Title = %q, want %q", info.Title, "Fix the widget")
	}
	if info.Description != "Widget is broken" {
		t.Errorf("Description = %q, want %q", info.Description, "Widget is broken")
	}
	if info.Effort != "M" {
		t.Errorf("Effort = %q, want %q", info.Effort, "M")
	}
}

func TestReadTask_Missing(t *testing.T) {
	client := newTestClient(t)

	_, err := ReadTask(context.Background(), client, "agentex", "nonexistent-task")
	if err == nil {
		t.Fatal("expected error for missing task, got nil")
	}
}

func TestReadTask_NoIssueNumber(t *testing.T) {
	taskCR := makeTaskCR("task-bad", "agentex", 0, "No issue", "desc", "S")
	client := newTestClient(t, taskCR)

	_, err := ReadTask(context.Background(), client, "agentex", "task-bad")
	if err == nil {
		t.Fatal("expected error for zero issueNumber, got nil")
	}
}

func TestReadTask_StringIssueNumber(t *testing.T) {
	taskCR := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8s.KroGroup + "/" + k8s.KroVersion,
			"kind":       "Task",
			"metadata": map[string]interface{}{
				"name":      "task-str",
				"namespace": "agentex",
			},
			"spec": map[string]interface{}{
				"issueNumber": "99",
				"title":       "String number task",
				"description": "Testing string issue number",
				"effort":      "L",
			},
		},
	}
	client := newTestClient(t, taskCR)

	info, err := ReadTask(context.Background(), client, "agentex", "task-str")
	if err != nil {
		t.Fatalf("ReadTask returned error: %v", err)
	}
	if info.IssueNumber != 99 {
		t.Errorf("IssueNumber = %d, want 99", info.IssueNumber)
	}
}

// --- TestRenderAgentPrompt ---

func TestRenderAgentPrompt_Operator(t *testing.T) {
	registry := roles.NewRegistry()
	err := registry.Register(&roles.Role{
		Name:        "operator",
		Description: "Test operator",
		Prompt: roles.PromptTemplate{
			System: "You are an operator for {repo}.",
			Task:   "Work on #{issue_number}: {issue_title}\n{issue_body}",
			Rules:  []string{"Always include Closes #{issue_number}"},
			Vars: map[string]string{
				"issue_number": "0",
				"issue_title":  "unassigned",
				"issue_slug":   "unassigned",
				"issue_body":   "",
				"repo":         "pnz1990/agentex",
			},
		},
		Capabilities: []string{"git"},
		Lifecycle:    roles.LifecycleConfig{Type: "ephemeral"},
		Resources:    roles.ResourceConfig{Model: "claude-sonnet"},
	})
	if err != nil {
		t.Fatalf("Register: %v", err)
	}

	task := &TaskInfo{
		IssueNumber: 123,
		Title:       "Add metrics endpoint",
		Description: "We need /metrics for Prometheus.",
	}

	prompt, err := RenderAgentPrompt(registry, "operator", task, "pnz1990/agentex")
	if err != nil {
		t.Fatalf("RenderAgentPrompt: %v", err)
	}

	checks := []struct {
		needle string
		desc   string
	}{
		{"pnz1990/agentex", "repo"},
		{"#123", "issue number"},
		{"Add metrics endpoint", "issue title"},
		{"We need /metrics for Prometheus.", "issue body"},
		{"Closes #123", "closes directive"},
	}
	for _, c := range checks {
		if !strings.Contains(prompt, c.needle) {
			t.Errorf("prompt missing %s (%q)\nprompt:\n%s", c.desc, c.needle, prompt)
		}
	}
}

func TestRenderAgentPrompt_UnknownRole(t *testing.T) {
	registry := roles.NewRegistry()

	task := &TaskInfo{IssueNumber: 1, Title: "test"}
	_, err := RenderAgentPrompt(registry, "nonexistent", task, "repo")
	if err == nil {
		t.Fatal("expected error for unknown role, got nil")
	}
}

// --- TestDetectPRNumber ---

func TestDetectPRNumber_NoGH(t *testing.T) {
	// Verifies the function handles gh failures gracefully.
	_, err := DetectPRNumber("nonexistent-org/nonexistent-repo", 99999)
	if err == nil {
		return // gh available and authenticated; returns 0 which is fine
	}
	t.Logf("DetectPRNumber error (expected in test): %v", err)
}

// --- TestPostReport ---

func TestPostReport_Success(t *testing.T) {
	client := newTestClient(t)

	result := &ExecutionResult{
		Success:  true,
		PRNumber: 42,
		Phase:    PhaseReport,
	}

	err := PostReport(context.Background(), client, "agentex", "test-agent", result)
	if err != nil {
		t.Fatalf("PostReport: %v", err)
	}

	reports, err := client.ListCRs(context.Background(), "agentex", k8s.ReportGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("ListCRs: %v", err)
	}
	if len(reports.Items) != 1 {
		t.Fatalf("expected 1 report, got %d", len(reports.Items))
	}

	spec := reports.Items[0].Object["spec"].(map[string]interface{})
	if spec["agentRef"] != "test-agent" {
		t.Errorf("agentRef = %v, want test-agent", spec["agentRef"])
	}
	if spec["status"] != "success" {
		t.Errorf("status = %v, want success", spec["status"])
	}
	prNum, _ := spec["prNumber"].(int64)
	if prNum != 42 {
		t.Errorf("prNumber = %v, want 42", spec["prNumber"])
	}
}

func TestPostReport_Failure(t *testing.T) {
	client := newTestClient(t)

	result := &ExecutionResult{
		Success: false,
		Phase:   PhaseExecute,
		Error:   "opencode crashed",
	}

	err := PostReport(context.Background(), client, "agentex", "fail-agent", result)
	if err != nil {
		t.Fatalf("PostReport: %v", err)
	}

	reports, err := client.ListCRs(context.Background(), "agentex", k8s.ReportGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("ListCRs: %v", err)
	}
	if len(reports.Items) != 1 {
		t.Fatalf("expected 1 report, got %d", len(reports.Items))
	}

	spec := reports.Items[0].Object["spec"].(map[string]interface{})
	if spec["status"] != "failure" {
		t.Errorf("status = %v, want failure", spec["status"])
	}
	if spec["error"] != "opencode crashed" {
		t.Errorf("error = %v, want 'opencode crashed'", spec["error"])
	}
}

// --- TestSpawnSuccessor ---

func TestSpawnSuccessor(t *testing.T) {
	client := newTestClient(t)

	err := SpawnSuccessor(context.Background(), client, "agentex", "agent-42", "operator")
	if err != nil {
		t.Fatalf("SpawnSuccessor: %v", err)
	}

	tasks, err := client.ListCRs(context.Background(), "agentex", k8s.TaskGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("ListCRs tasks: %v", err)
	}
	if len(tasks.Items) != 1 {
		t.Fatalf("expected 1 task, got %d", len(tasks.Items))
	}
	taskSpec := tasks.Items[0].Object["spec"].(map[string]interface{})
	if taskSpec["effort"] != "M" {
		t.Errorf("task effort = %v, want M", taskSpec["effort"])
	}

	agents, err := client.ListCRs(context.Background(), "agentex", k8s.AgentGVR, metav1.ListOptions{})
	if err != nil {
		t.Fatalf("ListCRs agents: %v", err)
	}
	if len(agents.Items) != 1 {
		t.Fatalf("expected 1 agent, got %d", len(agents.Items))
	}
	agentSpec := agents.Items[0].Object["spec"].(map[string]interface{})
	if agentSpec["role"] != "operator" {
		t.Errorf("agent role = %v, want operator", agentSpec["role"])
	}

	taskName := tasks.Items[0].GetName()
	if agentSpec["taskRef"] != taskName {
		t.Errorf("agent taskRef = %v, want %v", agentSpec["taskRef"], taskName)
	}
}

// --- TestSlugify ---

func TestSlugify(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"Fix the Widget", "fix-the-widget"},
		{"Add metrics/endpoint", "add-metrics-endpoint"},
		{"  spaces  ", "spaces"},
		{"UPPERCASE", "uppercase"},
		{"a-very-long-title-that-exceeds-forty-characters-limit-here", "a-very-long-title-that-exceeds-forty-cha"},
	}
	for _, tt := range tests {
		got := slugify(tt.input)
		if got != tt.want {
			t.Errorf("slugify(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

// --- TestLoadFromEnv ---

func TestLoadFromEnv_Required(t *testing.T) {
	for _, key := range []string{"AGENT_NAME", "AGENT_ROLE", "TASK_CR_NAME", "REPO", "NAMESPACE", "BEDROCK_REGION", "BEDROCK_MODEL"} {
		t.Setenv(key, "")
	}

	cfg := &AgentConfig{}
	err := cfg.LoadFromEnv()
	if err == nil {
		t.Fatal("expected error with empty env, got nil")
	}

	t.Setenv("AGENT_NAME", "test-agent")
	t.Setenv("AGENT_ROLE", "operator")
	t.Setenv("TASK_CR_NAME", "task-123")

	cfg = &AgentConfig{}
	err = cfg.LoadFromEnv()
	if err != nil {
		t.Fatalf("LoadFromEnv with required vars: %v", err)
	}

	if cfg.Name != "test-agent" {
		t.Errorf("Name = %q, want test-agent", cfg.Name)
	}
	if cfg.Repo != "pnz1990/agentex" {
		t.Errorf("Repo = %q, want pnz1990/agentex", cfg.Repo)
	}
	if cfg.Namespace != "agentex" {
		t.Errorf("Namespace = %q, want agentex", cfg.Namespace)
	}
	if cfg.Region != "us-west-2" {
		t.Errorf("Region = %q, want us-west-2", cfg.Region)
	}
}
