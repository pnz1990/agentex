// Package agent implements the agent lifecycle as testable phases.
// It replaces the 4,335-line bash entrypoint.sh with structured Go code.
package agent

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/pnz1990/agentex/internal/k8s"
	"github.com/pnz1990/agentex/internal/roles"
)

// Phase represents a stage in the agent lifecycle.
type Phase string

const (
	PhaseInit     Phase = "init"
	PhaseReadTask Phase = "read-task"
	PhaseSetupGit Phase = "setup-git"
	PhaseExecute  Phase = "execute"
	PhaseReport   Phase = "report"
	PhaseSpawn    Phase = "spawn"
)

// AgentConfig holds agent identity and connection parameters from env vars.
type AgentConfig struct {
	Name       string
	Role       string
	TaskCRName string
	Repo       string
	Namespace  string
	Region     string
	Model      string
}

// LoadFromEnv populates AgentConfig from environment variables.
func (c *AgentConfig) LoadFromEnv() error {
	c.Name = os.Getenv("AGENT_NAME")
	c.Role = os.Getenv("AGENT_ROLE")
	c.TaskCRName = os.Getenv("TASK_CR_NAME")
	c.Repo = os.Getenv("REPO")
	c.Namespace = os.Getenv("NAMESPACE")
	c.Region = os.Getenv("BEDROCK_REGION")
	c.Model = os.Getenv("BEDROCK_MODEL")

	if c.Name == "" {
		return fmt.Errorf("AGENT_NAME is required")
	}
	if c.Role == "" {
		return fmt.Errorf("AGENT_ROLE is required")
	}
	if c.TaskCRName == "" {
		return fmt.Errorf("TASK_CR_NAME is required")
	}
	if c.Repo == "" {
		c.Repo = "pnz1990/agentex"
	}
	if c.Namespace == "" {
		c.Namespace = "agentex"
	}
	if c.Region == "" {
		c.Region = "us-west-2"
	}
	if c.Model == "" {
		c.Model = "us.anthropic.claude-sonnet-4-6"
	}
	return nil
}

// TaskInfo holds the parsed assignment from a Task CR.
type TaskInfo struct {
	IssueNumber int
	Title       string
	Description string
	Effort      string
}

// ExecutionResult captures the outcome of the OpenCode execution.
type ExecutionResult struct {
	Success  bool
	PRNumber int
	Error    string
	Phase    Phase
}

// ReadTask reads the Task CR and extracts assignment info.
func ReadTask(ctx context.Context, client *k8s.Client, namespace, taskCRName string) (*TaskInfo, error) {
	obj, err := client.GetCR(ctx, namespace, k8s.TaskGVR, taskCRName)
	if err != nil {
		return nil, fmt.Errorf("reading task CR %s: %w", taskCRName, err)
	}

	spec, ok := obj.Object["spec"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("task CR %s has no spec", taskCRName)
	}

	info := &TaskInfo{
		Title:       getString(spec, "title"),
		Description: getString(spec, "description"),
		Effort:      getString(spec, "effort"),
	}

	// Issue number can be int or string in the CR
	switch v := spec["issueNumber"].(type) {
	case int64:
		info.IssueNumber = int(v)
	case float64:
		info.IssueNumber = int(v)
	case string:
		info.IssueNumber, _ = strconv.Atoi(v)
	}

	if info.IssueNumber == 0 {
		return nil, fmt.Errorf("task CR %s has no issueNumber", taskCRName)
	}

	return info, nil
}

// SetupGitWorkspace clones the repo and creates a branch.
func SetupGitWorkspace(repo string, issueNumber int, workdir string) error {
	repoURL := fmt.Sprintf("https://github.com/%s", repo)

	if err := os.MkdirAll(workdir, 0o755); err != nil {
		return fmt.Errorf("creating workdir: %w", err)
	}

	// Clone
	cmd := exec.Command("git", "clone", "--depth=1", repoURL, workdir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("git clone: %w", err)
	}

	// Create branch
	branch := fmt.Sprintf("issue-%d", issueNumber)
	cmd = exec.Command("git", "checkout", "-b", branch)
	cmd.Dir = workdir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("git checkout -b %s: %w", branch, err)
	}

	return nil
}

// RenderAgentPrompt loads the role and renders the prompt with task info.
func RenderAgentPrompt(registry *roles.Registry, roleName string, task *TaskInfo, repo string) (string, error) {
	role, ok := registry.Get(roleName)
	if !ok {
		return "", fmt.Errorf("role %q not found in registry", roleName)
	}

	slug := slugify(task.Title)

	vars := map[string]string{
		"issue_number": strconv.Itoa(task.IssueNumber),
		"issue_title":  task.Title,
		"issue_slug":   slug,
		"issue_body":   task.Description,
		"repo":         repo,
	}

	return role.RenderPrompt(vars), nil
}

// ExecuteOpenCode runs the OpenCode CLI with the rendered prompt.
// It writes the prompt to a file and invokes opencode with it.
func ExecuteOpenCode(ctx context.Context, prompt string, workdir string, model string) (*ExecutionResult, error) {
	promptFile := filepath.Join(workdir, ".agent-prompt.md")
	if err := os.WriteFile(promptFile, []byte(prompt), 0o644); err != nil {
		return &ExecutionResult{Phase: PhaseExecute, Error: err.Error()}, err
	}

	// Build opencode command
	args := []string{"--prompt-file", promptFile}
	if model != "" {
		args = append(args, "--model", model)
	}

	cmd := exec.CommandContext(ctx, "opencode", args...)
	cmd.Dir = workdir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	err := cmd.Run()
	if err != nil {
		return &ExecutionResult{
			Phase: PhaseExecute,
			Error: fmt.Sprintf("opencode exited: %v", err),
		}, nil // Non-fatal: opencode may exit non-zero but still have done useful work
	}

	return &ExecutionResult{
		Success: true,
		Phase:   PhaseExecute,
	}, nil
}

// DetectPRNumber searches for the PR number using gh cli.
func DetectPRNumber(repo string, issueNumber int) (int, error) {
	branch := fmt.Sprintf("issue-%d", issueNumber)
	cmd := exec.Command("gh", "pr", "list",
		"--repo", repo,
		"--head", branch,
		"--json", "number",
		"--jq", ".[0].number",
	)
	out, err := cmd.Output()
	if err != nil {
		return 0, fmt.Errorf("gh pr list: %w", err)
	}

	s := strings.TrimSpace(string(out))
	if s == "" || s == "null" {
		return 0, nil
	}

	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("parsing PR number %q: %w", s, err)
	}
	return n, nil
}

// PostReport creates a Report CR with the execution result.
func PostReport(ctx context.Context, client *k8s.Client, namespace, agentName string, result *ExecutionResult) error {
	status := "success"
	if !result.Success {
		status = "failure"
	}

	name := fmt.Sprintf("report-%s-%d", agentName, time.Now().Unix())
	obj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8s.KroGroup + "/" + k8s.KroVersion,
			"kind":       "Report",
			"metadata": map[string]interface{}{
				"name":      name,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"agentRef":  agentName,
				"status":    status,
				"phase":     string(result.Phase),
				"prNumber":  int64(result.PRNumber),
				"error":     result.Error,
				"timestamp": time.Now().UTC().Format(time.RFC3339),
			},
		},
	}

	_, err := client.CreateCR(ctx, namespace, k8s.ReportGVR, obj)
	if err != nil {
		return fmt.Errorf("creating report CR: %w", err)
	}

	slog.Info("posted report", "name", name, "status", status)
	return nil
}

// SpawnSuccessor creates the next Task+Agent CR pair.
func SpawnSuccessor(ctx context.Context, client *k8s.Client, namespace, currentAgent, role string) error {
	ts := time.Now().Unix()
	taskName := fmt.Sprintf("task-successor-%s-%d", currentAgent, ts)
	agentName := fmt.Sprintf("agent-successor-%s-%d", currentAgent, ts)

	// Create Task CR
	taskObj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8s.KroGroup + "/" + k8s.KroVersion,
			"kind":       "Task",
			"metadata": map[string]interface{}{
				"name":      taskName,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"title":       fmt.Sprintf("Successor of %s", currentAgent),
				"description": "Continue platform improvement. Check coordinator for assigned task, implement and open PR.",
				"assignee":    agentName,
				"effort":      "M",
			},
		},
	}

	if _, err := client.CreateCR(ctx, namespace, k8s.TaskGVR, taskObj); err != nil {
		return fmt.Errorf("creating successor task CR: %w", err)
	}

	// Create Agent CR
	agentObj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8s.KroGroup + "/" + k8s.KroVersion,
			"kind":       "Agent",
			"metadata": map[string]interface{}{
				"name":      agentName,
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"role":    role,
				"taskRef": taskName,
				"reason":  fmt.Sprintf("Successor spawned by %s", currentAgent),
			},
		},
	}

	if _, err := client.CreateCR(ctx, namespace, k8s.AgentGVR, agentObj); err != nil {
		return fmt.Errorf("creating successor agent CR: %w", err)
	}

	slog.Info("spawned successor", "task", taskName, "agent", agentName, "role", role)
	return nil
}

// --- helpers ---

func getString(m map[string]interface{}, key string) string {
	v, ok := m[key]
	if !ok {
		return ""
	}
	s, ok := v.(string)
	if !ok {
		return fmt.Sprintf("%v", v)
	}
	return s
}

var nonAlphaNum = regexp.MustCompile(`[^a-z0-9]+`)

func slugify(s string) string {
	s = strings.ToLower(s)
	s = nonAlphaNum.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	if len(s) > 40 {
		s = s[:40]
	}
	return s
}
