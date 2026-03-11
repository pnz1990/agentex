// Package roles provides a role definition system for agentex agents.
// Each role defines the AI prompt, capabilities, lifecycle behavior, and
// resource requirements for a class of agent. Role definitions are loaded
// from YAML files and used by the coordinator and agent spawners to
// configure new agent pods.
package roles

import (
	"fmt"
	"strings"
)

// Role defines an agent role with its prompt, capabilities, and lifecycle rules.
type Role struct {
	Name         string          `yaml:"name" json:"name"`
	Description  string          `yaml:"description" json:"description"`
	Prompt       PromptTemplate  `yaml:"prompt" json:"prompt"`
	Capabilities []string        `yaml:"capabilities" json:"capabilities"`
	Lifecycle    LifecycleConfig `yaml:"lifecycle" json:"lifecycle"`
	Resources    ResourceConfig  `yaml:"resources" json:"resources"`
}

// PromptTemplate defines the AI prompt for a role.
type PromptTemplate struct {
	System string            `yaml:"system" json:"system"` // System/identity prompt
	Task   string            `yaml:"task" json:"task"`     // Task execution instructions
	Rules  []string          `yaml:"rules" json:"rules"`   // Hard rules the agent must follow
	Vars   map[string]string `yaml:"vars" json:"vars"`     // Default variable values
}

// LifecycleConfig defines how an agent of this role behaves.
type LifecycleConfig struct {
	Type           string `yaml:"type" json:"type"`                     // "ephemeral" (Job) or "persistent" (Deployment)
	SpawnSuccessor bool   `yaml:"spawnSuccessor" json:"spawnSuccessor"` // Whether to spawn successor on exit
	MaxDuration    string `yaml:"maxDuration" json:"maxDuration"`       // Maximum runtime (e.g. "30m")
	ClaimTask      bool   `yaml:"claimTask" json:"claimTask"`           // Whether this role claims tasks
}

// ResourceConfig defines Kubernetes resource requirements.
type ResourceConfig struct {
	CPU    string `yaml:"cpu" json:"cpu"`
	Memory string `yaml:"memory" json:"memory"`
	Model  string `yaml:"model" json:"model"`   // AI model to use (e.g. "claude-sonnet")
	Effort string `yaml:"effort" json:"effort"` // Model effort level (S/M/L)
}

// Validate checks that all required fields in a Role are set and valid.
func (r *Role) Validate() error {
	if r.Name == "" {
		return fmt.Errorf("role name is required")
	}
	if r.Description == "" {
		return fmt.Errorf("role %q: description is required", r.Name)
	}
	if r.Prompt.System == "" {
		return fmt.Errorf("role %q: prompt.system is required", r.Name)
	}
	if r.Prompt.Task == "" {
		return fmt.Errorf("role %q: prompt.task is required", r.Name)
	}
	if len(r.Capabilities) == 0 {
		return fmt.Errorf("role %q: at least one capability is required", r.Name)
	}

	switch r.Lifecycle.Type {
	case "ephemeral", "persistent":
		// valid
	case "":
		return fmt.Errorf("role %q: lifecycle.type is required (ephemeral or persistent)", r.Name)
	default:
		return fmt.Errorf("role %q: lifecycle.type must be 'ephemeral' or 'persistent', got %q", r.Name, r.Lifecycle.Type)
	}

	if r.Resources.Model == "" {
		return fmt.Errorf("role %q: resources.model is required", r.Name)
	}

	return nil
}

// RenderPrompt takes a map of variables (e.g. issue_number, issue_title, repo)
// and renders the full prompt by substituting {var_name} placeholders in the
// System, Task, and Rules fields. Default values from Prompt.Vars are used
// for any variables not provided in the input map.
func (r *Role) RenderPrompt(vars map[string]string) string {
	// Merge defaults with provided vars; provided vars take precedence.
	merged := make(map[string]string, len(r.Prompt.Vars)+len(vars))
	for k, v := range r.Prompt.Vars {
		merged[k] = v
	}
	for k, v := range vars {
		merged[k] = v
	}

	substitute := func(s string) string {
		result := s
		for k, v := range merged {
			result = strings.ReplaceAll(result, "{"+k+"}", v)
		}
		return result
	}

	var b strings.Builder

	// System section
	system := substitute(r.Prompt.System)
	b.WriteString(system)
	if !strings.HasSuffix(system, "\n") {
		b.WriteByte('\n')
	}

	// Task section
	b.WriteByte('\n')
	task := substitute(r.Prompt.Task)
	b.WriteString(task)
	if !strings.HasSuffix(task, "\n") {
		b.WriteByte('\n')
	}

	// Rules section
	if len(r.Prompt.Rules) > 0 {
		b.WriteString("\nRules:\n")
		for _, rule := range r.Prompt.Rules {
			b.WriteString("- ")
			b.WriteString(substitute(rule))
			b.WriteByte('\n')
		}
	}

	return b.String()
}
