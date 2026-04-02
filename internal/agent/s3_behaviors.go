package agent

// s3_behaviors.go — S3-based civilizational signal behaviors for flight test / mock mode.
//
// This file implements the S3 write behaviors that real agents perform via helpers.sh:
//   - write_planning_state  → s3://<bucket>/<prefix>planning/<agent>.json
//   - write_swarm_memory    → s3://<bucket>/<prefix>swarm/<name>-<ts>.json  (per-agent)
//     OR when FLIGHT_SWARM_NAME is set:
//                           → s3://<bucket>/<prefix>swarm-memories/<swarmName>.json (shared, append)
//   - update_identity_stats → s3://<bucket>/<prefix>identity/<agent>.json
//   - post_chronicle_candidate → s3://<bucket>/<prefix>chronicle-candidates/<agent>-<ts>.json
//
// In flight test mode the mock agent calls RunS3Behaviors() after RunFlightBehaviors().
// All writes use the E2E_S3_PREFIX (default "e2e/") key prefix so they don't pollute
// production data. Failures are logged but never propagate.

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	agentexs3 "github.com/pnz1990/agentex/internal/s3"
)

// S3BehaviorConfig controls which S3 signals the mock agent writes.
// All fields are populated from env vars by LoadS3BehaviorConfig().
type S3BehaviorConfig struct {
	// Enabled gates the entire S3 behavior block (FLIGHT_S3_ENABLED, default false).
	// S3 behaviors are off by default so basic dispatch tests don't need S3 access.
	Enabled bool

	// PlanningEnabled writes a planning state JSON to S3 (FLIGHT_PLANNING_ENABLED).
	PlanningEnabled bool

	// SwarmEnabled writes a swarm memory JSON to S3 (FLIGHT_SWARM_ENABLED).
	SwarmEnabled bool

	// SwarmName is the shared swarm name set by FLIGHT_SWARM_NAME.
	// When non-empty each agent appends itself to
	// "swarm-memories/<SwarmName>.json" (read-modify-write) rather than
	// writing an isolated per-agent key under "swarm/".
	SwarmName string

	// IdentityEnabled writes an identity stats JSON to S3 (FLIGHT_IDENTITY_ENABLED).
	IdentityEnabled bool

	// ChronicleEnabled writes a chronicle candidate JSON to S3 (FLIGHT_CHRONICLE_ENABLED).
	ChronicleEnabled bool
}

// LoadS3BehaviorConfig reads S3BehaviorConfig from environment variables.
func LoadS3BehaviorConfig() *S3BehaviorConfig {
	cfg := &S3BehaviorConfig{}

	if os.Getenv("FLIGHT_S3_ENABLED") == "true" {
		cfg.Enabled = true
	}
	if os.Getenv("FLIGHT_PLANNING_ENABLED") == "true" {
		cfg.PlanningEnabled = true
		cfg.Enabled = true
	}
	if os.Getenv("FLIGHT_SWARM_ENABLED") == "true" {
		cfg.SwarmEnabled = true
		cfg.Enabled = true
	}
	if v := os.Getenv("FLIGHT_SWARM_NAME"); v != "" {
		cfg.SwarmName = v
		cfg.SwarmEnabled = true
		cfg.Enabled = true
	}
	if os.Getenv("FLIGHT_IDENTITY_ENABLED") == "true" {
		cfg.IdentityEnabled = true
		cfg.Enabled = true
	}
	if os.Getenv("FLIGHT_CHRONICLE_ENABLED") == "true" {
		cfg.ChronicleEnabled = true
		cfg.Enabled = true
	}

	return cfg
}

// RunS3Behaviors executes all enabled S3 civilizational behaviors for a mock agent.
// It is called after RunFlightBehaviors. Failures are logged but never propagate.
func RunS3Behaviors(ctx context.Context, s3Client *agentexs3.Client, agentCfg *AgentConfig, s3Cfg *S3BehaviorConfig, task *TaskInfo) {
	if !s3Cfg.Enabled {
		slog.Info("s3 behaviors: disabled (FLIGHT_S3_ENABLED not set)")
		return
	}

	slog.Info("s3 behaviors: starting",
		"planning", s3Cfg.PlanningEnabled,
		"swarm", s3Cfg.SwarmEnabled,
		"identity", s3Cfg.IdentityEnabled,
		"chronicle", s3Cfg.ChronicleEnabled,
	)

	if s3Cfg.PlanningEnabled {
		if err := writePlanningState(ctx, s3Client, agentCfg, task); err != nil {
			slog.Warn("s3 behaviors: failed to write planning state", "error", err)
		}
	}

	if s3Cfg.SwarmEnabled {
		if err := writeSwarmMemory(ctx, s3Client, agentCfg, s3Cfg, task); err != nil {
			slog.Warn("s3 behaviors: failed to write swarm memory", "error", err)
		}
	}

	if s3Cfg.IdentityEnabled {
		if err := writeIdentity(ctx, s3Client, agentCfg, task); err != nil {
			slog.Warn("s3 behaviors: failed to write identity", "error", err)
		}
	}

	if s3Cfg.ChronicleEnabled {
		if err := writeChronicleCandidate(ctx, s3Client, agentCfg, task); err != nil {
			slog.Warn("s3 behaviors: failed to write chronicle candidate", "error", err)
		}
	}

	slog.Info("s3 behaviors: complete")
}

// writePlanningState writes the agent's planning state to S3.
// Key: planning/<agentName>.json
func writePlanningState(ctx context.Context, s3Client *agentexs3.Client, cfg *AgentConfig, task *TaskInfo) error {
	state := agentexs3.S3PlanningState{
		AgentName:   cfg.Name,
		Role:        cfg.Role,
		CurrentWork: fmt.Sprintf("flight-test: completed issue #%d — %s", task.IssueNumber, task.Title),
		N1Priority:  "continue platform improvement",
		N2Priority:  "expand e2e coverage",
		Blockers:    "none",
		Timestamp:   time.Now().UTC(),
	}

	key := fmt.Sprintf("planning/%s.json", cfg.Name)
	if err := s3Client.PutJSON(ctx, key, state); err != nil {
		return fmt.Errorf("planning state %s: %w", key, err)
	}
	slog.Info("s3: wrote planning state", "key", key)
	return nil
}

// writeSwarmMemory writes a swarm memory entry to S3.
//
// When s3Cfg.SwarmName is set (FLIGHT_SWARM_NAME), the agent performs a
// read-modify-write to append itself to the shared swarm memory object at
// "swarm-memories/<SwarmName>.json". This lets TestSwarmMemory verify that
// all 3 concurrent agents appear in the same S3 object's members array.
//
// When SwarmName is empty, the legacy per-agent write is used:
// Key: swarm/<agentName>-<timestamp>.json
func writeSwarmMemory(ctx context.Context, s3Client *agentexs3.Client, cfg *AgentConfig, s3Cfg *S3BehaviorConfig, task *TaskInfo) error {
	if s3Cfg.SwarmName != "" {
		return writeSharedSwarmMemory(ctx, s3Client, cfg, s3Cfg.SwarmName, task)
	}
	return writePerAgentSwarmMemory(ctx, s3Client, cfg, task)
}

// writeSharedSwarmMemory appends this agent to a shared swarm memory object.
// Key: swarm-memories/<swarmName>.json
// It performs a read-modify-write with a simple retry to handle concurrent writes.
func writeSharedSwarmMemory(ctx context.Context, s3Client *agentexs3.Client, cfg *AgentConfig, swarmName string, task *TaskInfo) error {
	key := fmt.Sprintf("swarm-memories/%s.json", swarmName)

	// Retry up to 5 times to handle concurrent writes from multiple agents.
	const maxRetries = 5
	for attempt := 0; attempt < maxRetries; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt*200) * time.Millisecond)
		}

		// Try to read the existing shared memory.
		var existing agentexs3.S3SwarmMemory
		readErr := s3Client.GetJSON(ctx, key, &existing)

		if readErr != nil {
			// First writer: initialise the object.
			existing = agentexs3.S3SwarmMemory{
				SwarmName: swarmName,
				Goal:      fmt.Sprintf("flight test swarm: %s", swarmName),
				Members:   []string{},
				Tasks:     []string{},
				Decisions: []string{},
				Origin:    cfg.Name,
				Timestamp: time.Now().UTC(),
			}
		}

		// Append this agent if not already present.
		alreadyMember := false
		for _, m := range existing.Members {
			if m == cfg.Name {
				alreadyMember = true
				break
			}
		}
		if !alreadyMember {
			existing.Members = append(existing.Members, cfg.Name)
			existing.Tasks = append(existing.Tasks, fmt.Sprintf("issue-%d", task.IssueNumber))
			existing.Decisions = append(existing.Decisions,
				fmt.Sprintf("%s (role=%s) joined swarm for issue #%d", cfg.Name, cfg.Role, task.IssueNumber))
			existing.Timestamp = time.Now().UTC()
		}

		if err := s3Client.PutJSON(ctx, key, existing); err != nil {
			if attempt < maxRetries-1 {
				slog.Warn("s3: shared swarm write conflict, retrying", "attempt", attempt, "error", err)
				continue
			}
			return fmt.Errorf("shared swarm memory %s: %w", key, err)
		}
		slog.Info("s3: wrote shared swarm memory", "key", key, "members", len(existing.Members))
		return nil
	}
	return fmt.Errorf("shared swarm memory %s: exceeded max retries", key)
}

// writePerAgentSwarmMemory writes an individual swarm memory entry.
// Key: swarm/<agentName>-<timestamp>.json
func writePerAgentSwarmMemory(ctx context.Context, s3Client *agentexs3.Client, cfg *AgentConfig, task *TaskInfo) error {
	ts := time.Now().UTC()
	mem := agentexs3.S3SwarmMemory{
		SwarmName: fmt.Sprintf("flight-test-swarm-%s", cfg.Name),
		Goal:      fmt.Sprintf("flight test: work on issue #%d", task.IssueNumber),
		Members:   []string{cfg.Name},
		Tasks:     []string{fmt.Sprintf("issue-%d", task.IssueNumber)},
		Decisions: []string{
			fmt.Sprintf("assigned issue #%d to %s (role=%s)", task.IssueNumber, cfg.Name, cfg.Role),
		},
		Origin:    cfg.Name,
		Timestamp: ts,
	}

	key := fmt.Sprintf("swarm/%s-%d.json", cfg.Name, ts.UnixNano())
	if err := s3Client.PutJSON(ctx, key, mem); err != nil {
		return fmt.Errorf("swarm memory %s: %w", key, err)
	}
	slog.Info("s3: wrote swarm memory", "key", key)
	return nil
}

// writeIdentity writes the agent's identity stats to S3.
// Key: identity/<agentName>.json
func writeIdentity(ctx context.Context, s3Client *agentexs3.Client, cfg *AgentConfig, task *TaskInfo) error {
	identity := agentexs3.S3Identity{
		AgentName:      cfg.Name,
		Role:           cfg.Role,
		Specialization: fmt.Sprintf("flight-test-%s", cfg.Role),
		Stats: map[string]int{
			"tasksCompleted": 1,
			"thoughtsPosted": 2,
			"issuesWorked":   task.IssueNumber,
		},
		Timestamp: time.Now().UTC(),
	}

	key := fmt.Sprintf("identity/%s.json", cfg.Name)
	if err := s3Client.PutJSON(ctx, key, identity); err != nil {
		return fmt.Errorf("identity %s: %w", key, err)
	}
	slog.Info("s3: wrote identity", "key", key)
	return nil
}

// writeChronicleCandidate writes a chronicle candidate entry to S3.
// Key: chronicle-candidates/<agentName>-<timestamp>.json
func writeChronicleCandidate(ctx context.Context, s3Client *agentexs3.Client, cfg *AgentConfig, task *TaskInfo) error {
	ts := time.Now().UTC()
	candidate := agentexs3.S3Chronicle{
		Era:       "flight-test",
		Summary:   fmt.Sprintf("Agent %s (role=%s) completed flight test for issue #%d: %s", cfg.Name, cfg.Role, task.IssueNumber, task.Title),
		Lesson:    "flight test mode validates the full coordinator lifecycle without real LLM calls",
		Milestone: false,
		Author:    cfg.Name,
		Timestamp: ts,
	}

	key := fmt.Sprintf("chronicle-candidates/%s-%d.json", cfg.Name, ts.UnixNano())
	if err := s3Client.PutJSON(ctx, key, candidate); err != nil {
		return fmt.Errorf("chronicle candidate %s: %w", key, err)
	}
	slog.Info("s3: wrote chronicle candidate", "key", key)
	return nil
}
