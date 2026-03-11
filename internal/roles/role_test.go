package roles

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

// validRole returns a fully populated Role for testing.
func validRole(name string) *Role {
	return &Role{
		Name:        name,
		Description: "A test role for " + name,
		Prompt: PromptTemplate{
			System: "You are a test agent.",
			Task:   "Do the thing for {issue_number}.",
			Rules:  []string{"Follow the rules for {repo}."},
			Vars: map[string]string{
				"issue_number": "0",
				"repo":         "test/repo",
			},
		},
		Capabilities: []string{"git", "code-editing"},
		Lifecycle: LifecycleConfig{
			Type:           "ephemeral",
			SpawnSuccessor: true,
			MaxDuration:    "30m",
			ClaimTask:      true,
		},
		Resources: ResourceConfig{
			CPU:    "500m",
			Memory: "512Mi",
			Model:  "claude-sonnet",
			Effort: "M",
		},
	}
}

// --- Validation tests ---

func TestRoleValidation_Valid(t *testing.T) {
	role := validRole("worker")
	if err := role.Validate(); err != nil {
		t.Fatalf("expected valid role, got error: %v", err)
	}
}

func TestRoleValidation_MissingName(t *testing.T) {
	role := validRole("worker")
	role.Name = ""
	err := role.Validate()
	if err == nil {
		t.Fatal("expected error for missing name")
	}
	if !strings.Contains(err.Error(), "name is required") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRoleValidation_MissingDescription(t *testing.T) {
	role := validRole("worker")
	role.Description = ""
	err := role.Validate()
	if err == nil {
		t.Fatal("expected error for missing description")
	}
	if !strings.Contains(err.Error(), "description is required") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRoleValidation_MissingSystemPrompt(t *testing.T) {
	role := validRole("worker")
	role.Prompt.System = ""
	err := role.Validate()
	if err == nil {
		t.Fatal("expected error for missing system prompt")
	}
	if !strings.Contains(err.Error(), "prompt.system is required") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRoleValidation_MissingTaskPrompt(t *testing.T) {
	role := validRole("worker")
	role.Prompt.Task = ""
	err := role.Validate()
	if err == nil {
		t.Fatal("expected error for missing task prompt")
	}
	if !strings.Contains(err.Error(), "prompt.task is required") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRoleValidation_EmptyCapabilities(t *testing.T) {
	role := validRole("worker")
	role.Capabilities = nil
	err := role.Validate()
	if err == nil {
		t.Fatal("expected error for empty capabilities")
	}
	if !strings.Contains(err.Error(), "at least one capability") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRoleValidation_MissingLifecycleType(t *testing.T) {
	role := validRole("worker")
	role.Lifecycle.Type = ""
	err := role.Validate()
	if err == nil {
		t.Fatal("expected error for missing lifecycle type")
	}
	if !strings.Contains(err.Error(), "lifecycle.type is required") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRoleValidation_InvalidLifecycleType(t *testing.T) {
	role := validRole("worker")
	role.Lifecycle.Type = "daemon"
	err := role.Validate()
	if err == nil {
		t.Fatal("expected error for invalid lifecycle type")
	}
	if !strings.Contains(err.Error(), "must be 'ephemeral' or 'persistent'") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRoleValidation_PersistentLifecycle(t *testing.T) {
	role := validRole("coordinator")
	role.Lifecycle.Type = "persistent"
	if err := role.Validate(); err != nil {
		t.Fatalf("expected persistent lifecycle to be valid, got: %v", err)
	}
}

func TestRoleValidation_MissingModel(t *testing.T) {
	role := validRole("worker")
	role.Resources.Model = ""
	err := role.Validate()
	if err == nil {
		t.Fatal("expected error for missing model")
	}
	if !strings.Contains(err.Error(), "resources.model is required") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// --- RenderPrompt tests ---

func TestRenderPrompt_BasicSubstitution(t *testing.T) {
	role := validRole("worker")
	result := role.RenderPrompt(map[string]string{
		"issue_number": "42",
		"repo":         "pnz1990/agentex",
	})

	if !strings.Contains(result, "Do the thing for 42.") {
		t.Errorf("expected issue_number substitution, got:\n%s", result)
	}
	if !strings.Contains(result, "Follow the rules for pnz1990/agentex.") {
		t.Errorf("expected repo substitution in rules, got:\n%s", result)
	}
}

func TestRenderPrompt_DefaultVars(t *testing.T) {
	role := validRole("worker")
	// Pass no vars — defaults from Prompt.Vars should be used.
	result := role.RenderPrompt(nil)

	if !strings.Contains(result, "Do the thing for 0.") {
		t.Errorf("expected default issue_number=0, got:\n%s", result)
	}
	if !strings.Contains(result, "Follow the rules for test/repo.") {
		t.Errorf("expected default repo=test/repo, got:\n%s", result)
	}
}

func TestRenderPrompt_OverrideDefaults(t *testing.T) {
	role := validRole("worker")
	result := role.RenderPrompt(map[string]string{
		"issue_number": "99",
		// repo not overridden — should use default
	})

	if !strings.Contains(result, "Do the thing for 99.") {
		t.Errorf("expected overridden issue_number=99, got:\n%s", result)
	}
	if !strings.Contains(result, "Follow the rules for test/repo.") {
		t.Errorf("expected default repo=test/repo, got:\n%s", result)
	}
}

func TestRenderPrompt_MissingVarsLeftAsIs(t *testing.T) {
	role := &Role{
		Name:        "test",
		Description: "test",
		Prompt: PromptTemplate{
			System: "Hello {name}.",
			Task:   "Work on {unknown_var}.",
			Rules:  []string{"Rule {another_missing}."},
		},
		Capabilities: []string{"git"},
		Lifecycle:    LifecycleConfig{Type: "ephemeral"},
		Resources:    ResourceConfig{Model: "claude-sonnet"},
	}

	result := role.RenderPrompt(map[string]string{"name": "Alice"})

	if !strings.Contains(result, "Hello Alice.") {
		t.Errorf("expected name substitution, got:\n%s", result)
	}
	// Unmatched placeholders remain as-is
	if !strings.Contains(result, "{unknown_var}") {
		t.Errorf("expected {unknown_var} to remain, got:\n%s", result)
	}
	if !strings.Contains(result, "{another_missing}") {
		t.Errorf("expected {another_missing} to remain, got:\n%s", result)
	}
}

func TestRenderPrompt_ExtraVarsIgnored(t *testing.T) {
	role := validRole("worker")
	result := role.RenderPrompt(map[string]string{
		"issue_number": "1",
		"repo":         "test/repo",
		"extra_var":    "should-not-crash",
		"another":      "also-fine",
	})

	if !strings.Contains(result, "Do the thing for 1.") {
		t.Errorf("expected issue_number substitution, got:\n%s", result)
	}
	// Extra vars should not cause errors
	if strings.Contains(result, "should-not-crash") {
		t.Errorf("extra vars should not appear in output unless there's a matching placeholder")
	}
}

func TestRenderPrompt_StructureContainsAllSections(t *testing.T) {
	role := validRole("worker")
	result := role.RenderPrompt(nil)

	if !strings.Contains(result, "You are a test agent.") {
		t.Error("missing system section")
	}
	if !strings.Contains(result, "Do the thing") {
		t.Error("missing task section")
	}
	if !strings.Contains(result, "Rules:") {
		t.Error("missing rules header")
	}
	if !strings.Contains(result, "- Follow the rules") {
		t.Error("missing rule entry")
	}
}

func TestRenderPrompt_NoRules(t *testing.T) {
	role := validRole("worker")
	role.Prompt.Rules = nil
	result := role.RenderPrompt(nil)

	if strings.Contains(result, "Rules:") {
		t.Error("should not have Rules header when there are no rules")
	}
}

// --- Registry tests ---

func TestRegistryRegister(t *testing.T) {
	reg := NewRegistry()
	role := validRole("operator")

	if err := reg.Register(role); err != nil {
		t.Fatalf("register failed: %v", err)
	}

	got, ok := reg.Get("operator")
	if !ok {
		t.Fatal("expected to find registered role")
	}
	if got.Name != "operator" {
		t.Errorf("expected name 'operator', got %q", got.Name)
	}
}

func TestRegistryRegister_Duplicate(t *testing.T) {
	reg := NewRegistry()
	role := validRole("operator")

	if err := reg.Register(role); err != nil {
		t.Fatalf("first register failed: %v", err)
	}

	err := reg.Register(validRole("operator"))
	if err == nil {
		t.Fatal("expected error for duplicate registration")
	}
	if !strings.Contains(err.Error(), "already registered") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRegistryRegister_InvalidRole(t *testing.T) {
	reg := NewRegistry()
	role := &Role{Name: ""} // invalid — no name
	err := reg.Register(role)
	if err == nil {
		t.Fatal("expected error for invalid role")
	}
}

func TestRegistryGet_NotFound(t *testing.T) {
	reg := NewRegistry()
	_, ok := reg.Get("nonexistent")
	if ok {
		t.Fatal("expected not found")
	}
}

func TestRegistryList(t *testing.T) {
	reg := NewRegistry()
	_ = reg.Register(validRole("charlie"))
	_ = reg.Register(validRole("alpha"))
	_ = reg.Register(validRole("bravo"))

	names := reg.List()
	expected := []string{"alpha", "bravo", "charlie"}

	if len(names) != len(expected) {
		t.Fatalf("expected %d names, got %d", len(expected), len(names))
	}
	for i, name := range names {
		if name != expected[i] {
			t.Errorf("expected names[%d]=%q, got %q", i, expected[i], name)
		}
	}
}

func TestRegistryList_Empty(t *testing.T) {
	reg := NewRegistry()
	names := reg.List()
	if len(names) != 0 {
		t.Fatalf("expected empty list, got %v", names)
	}
}

// --- Registry Load tests ---

const testRoleYAML = `name: test-role
description: "A test role"
prompt:
  system: "You are a test agent."
  task: "Do the task."
  rules:
    - "Rule one"
capabilities:
  - git
lifecycle:
  type: ephemeral
  spawnSuccessor: true
  maxDuration: "10m"
  claimTask: true
resources:
  cpu: "250m"
  memory: "256Mi"
  model: "claude-sonnet"
  effort: "S"
`

func TestRegistryLoad_FromDir(t *testing.T) {
	dir := t.TempDir()

	// Write a valid YAML file
	if err := os.WriteFile(filepath.Join(dir, "test.yaml"), []byte(testRoleYAML), 0644); err != nil {
		t.Fatal(err)
	}

	// Write a non-YAML file that should be ignored
	if err := os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("ignore me"), 0644); err != nil {
		t.Fatal(err)
	}

	reg := NewRegistry()
	if err := reg.Load(dir); err != nil {
		t.Fatalf("load failed: %v", err)
	}

	role, ok := reg.Get("test-role")
	if !ok {
		t.Fatal("expected to find test-role")
	}
	if role.Description != "A test role" {
		t.Errorf("unexpected description: %q", role.Description)
	}
	if role.Lifecycle.Type != "ephemeral" {
		t.Errorf("unexpected lifecycle type: %q", role.Lifecycle.Type)
	}
	if role.Resources.Model != "claude-sonnet" {
		t.Errorf("unexpected model: %q", role.Resources.Model)
	}
}

func TestRegistryLoad_YMLExtension(t *testing.T) {
	dir := t.TempDir()

	if err := os.WriteFile(filepath.Join(dir, "role.yml"), []byte(testRoleYAML), 0644); err != nil {
		t.Fatal(err)
	}

	reg := NewRegistry()
	if err := reg.Load(dir); err != nil {
		t.Fatalf("load .yml failed: %v", err)
	}

	if _, ok := reg.Get("test-role"); !ok {
		t.Fatal("expected to find test-role from .yml file")
	}
}

func TestRegistryLoad_InvalidYAML(t *testing.T) {
	dir := t.TempDir()

	if err := os.WriteFile(filepath.Join(dir, "bad.yaml"), []byte("{{{{invalid yaml"), 0644); err != nil {
		t.Fatal(err)
	}

	reg := NewRegistry()
	err := reg.Load(dir)
	if err == nil {
		t.Fatal("expected error for invalid YAML")
	}
	if !strings.Contains(err.Error(), "parsing role") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRegistryLoad_InvalidRole(t *testing.T) {
	dir := t.TempDir()

	// Valid YAML but invalid role (missing required fields)
	badRole := `name: incomplete
description: ""
`
	if err := os.WriteFile(filepath.Join(dir, "bad.yaml"), []byte(badRole), 0644); err != nil {
		t.Fatal(err)
	}

	reg := NewRegistry()
	err := reg.Load(dir)
	if err == nil {
		t.Fatal("expected error for invalid role")
	}
	if !strings.Contains(err.Error(), "validating role") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRegistryLoad_EmptyDir(t *testing.T) {
	dir := t.TempDir()

	reg := NewRegistry()
	if err := reg.Load(dir); err != nil {
		t.Fatalf("empty dir should not error: %v", err)
	}

	if len(reg.List()) != 0 {
		t.Fatal("expected empty registry")
	}
}

func TestRegistryLoad_NonexistentDir(t *testing.T) {
	reg := NewRegistry()
	err := reg.Load("/nonexistent/path/that/does/not/exist")
	if err == nil {
		t.Fatal("expected error for nonexistent directory")
	}
}

func TestRegistryLoad_MultipleFiles(t *testing.T) {
	dir := t.TempDir()

	role1 := strings.Replace(testRoleYAML, "test-role", "role-alpha", 1)
	role2 := strings.Replace(testRoleYAML, "test-role", "role-bravo", 1)

	if err := os.WriteFile(filepath.Join(dir, "alpha.yaml"), []byte(role1), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bravo.yaml"), []byte(role2), 0644); err != nil {
		t.Fatal(err)
	}

	reg := NewRegistry()
	if err := reg.Load(dir); err != nil {
		t.Fatalf("load failed: %v", err)
	}

	names := reg.List()
	if len(names) != 2 {
		t.Fatalf("expected 2 roles, got %d: %v", len(names), names)
	}
}

// --- LoadFromFS tests ---

func TestRegistryLoadFromFS(t *testing.T) {
	fsys := fstest.MapFS{
		"operator.yaml": &fstest.MapFile{Data: []byte(testRoleYAML)},
		"readme.txt":    &fstest.MapFile{Data: []byte("not a role")},
	}

	reg := NewRegistry()
	if err := reg.LoadFromFS(fsys); err != nil {
		t.Fatalf("LoadFromFS failed: %v", err)
	}

	if _, ok := reg.Get("test-role"); !ok {
		t.Fatal("expected to find test-role from FS")
	}
}

func TestRegistryLoadFromFS_InvalidYAML(t *testing.T) {
	fsys := fstest.MapFS{
		"bad.yaml": &fstest.MapFile{Data: []byte("{{bad")},
	}

	reg := NewRegistry()
	err := reg.LoadFromFS(fsys)
	if err == nil {
		t.Fatal("expected error for invalid YAML in FS")
	}
}

func TestRegistryLoadFromFS_Empty(t *testing.T) {
	fsys := fstest.MapFS{}

	reg := NewRegistry()
	if err := reg.LoadFromFS(fsys); err != nil {
		t.Fatalf("empty FS should not error: %v", err)
	}
	if len(reg.List()) != 0 {
		t.Fatal("expected empty registry")
	}
}

// --- Integration: load the actual roles/ directory ---

func TestLoadActualRoles(t *testing.T) {
	// This test loads the real role YAML files from the project's roles/ directory.
	// It skips if the directory doesn't exist (e.g. in CI before files are written).
	rolesDir := filepath.Join("..", "..", "roles")
	if _, err := os.Stat(rolesDir); os.IsNotExist(err) {
		t.Skip("roles/ directory not found, skipping integration test")
	}

	reg := NewRegistry()
	if err := reg.Load(rolesDir); err != nil {
		t.Fatalf("failed to load roles from %s: %v", rolesDir, err)
	}

	names := reg.List()
	if len(names) == 0 {
		t.Fatal("expected at least one role to be loaded")
	}

	t.Logf("loaded %d roles: %v", len(names), names)

	// Verify each loaded role renders a prompt without panicking
	for _, name := range names {
		role, _ := reg.Get(name)
		prompt := role.RenderPrompt(map[string]string{
			"issue_number": "123",
			"issue_title":  "Test issue",
			"issue_slug":   "test-issue",
			"issue_body":   "Do the thing.",
			"repo":         "pnz1990/agentex",
		})
		if prompt == "" {
			t.Errorf("role %q rendered empty prompt", name)
		}
	}
}
