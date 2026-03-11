// Package main is the entry point for the agentex agent binary.
// It replaces the 4,335-line bash entrypoint.sh with a compiled Go binary
// that executes the full agent lifecycle: read task, setup git, run OpenCode,
// report results, spawn successor.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/pnz1990/agentex/internal/agent"
	"github.com/pnz1990/agentex/internal/k8s"
	"github.com/pnz1990/agentex/internal/roles"
	roledefs "github.com/pnz1990/agentex/roles"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("agent failed", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	// Phase: init — load config from env vars
	cfg := &agent.AgentConfig{}
	if err := cfg.LoadFromEnv(); err != nil {
		return fmt.Errorf("[init] %w", err)
	}
	logger.Info("agent starting",
		"name", cfg.Name,
		"role", cfg.Role,
		"task", cfg.TaskCRName,
		"repo", cfg.Repo,
	)

	// Set up signal handling
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-sigCh
		logger.Info("received signal, shutting down", "signal", sig.String())
		cancel()
	}()

	// Create K8s client (in-cluster)
	client, err := k8s.NewClient("", logger)
	if err != nil {
		return fmt.Errorf("[init] k8s client: %w", err)
	}

	// Phase: read-task
	logger.Info("reading task CR", "name", cfg.TaskCRName)
	task, err := agent.ReadTask(ctx, client, cfg.Namespace, cfg.TaskCRName)
	if err != nil {
		return fmt.Errorf("[read-task] %w", err)
	}
	logger.Info("task loaded",
		"issue", task.IssueNumber,
		"title", task.Title,
	)

	// Load role definitions from embedded FS
	registry := roles.NewRegistry()
	if err := registry.LoadFromFS(roledefs.FS); err != nil {
		return fmt.Errorf("[init] loading roles: %w", err)
	}

	// Render prompt (skipped in flight test mode — no LLM call will be made)
	var prompt string
	if !cfg.FlightTest {
		var renderErr error
		prompt, renderErr = agent.RenderAgentPrompt(registry, cfg.Role, task, cfg.Repo)
		if renderErr != nil {
			return fmt.Errorf("[read-task] render prompt: %w", renderErr)
		}
	}

	// Phase: setup-git  (skipped in flight test mode)
	if cfg.FlightTest {
		logger.Info("flight test mode: skipping git workspace setup")
	} else {
		workdir := fmt.Sprintf("/workspace/issue-%d", task.IssueNumber)
		logger.Info("setting up git workspace", "workdir", workdir)
		if err := agent.SetupGitWorkspace(cfg.Repo, task.IssueNumber, workdir); err != nil {
			reportErr := agent.PostReport(ctx, client, cfg.Namespace, cfg.Name, &agent.ExecutionResult{
				Phase: agent.PhaseSetupGit,
				Error: err.Error(),
			})
			if reportErr != nil {
				logger.Error("failed to post error report", "error", reportErr)
			}
			return fmt.Errorf("[setup-git] %w", err)
		}
	}

	// Phase: execute
	var result *agent.ExecutionResult
	if cfg.FlightTest {
		logger.Info("flight test mode: executing mock agent",
			"sleepSeconds", cfg.MockSleepSeconds,
			"fail", cfg.MockFail,
		)
		var execErr error
		result, execErr = agent.ExecuteFlightTest(cfg)
		if execErr != nil {
			return fmt.Errorf("[execute] %w", execErr)
		}

		// Post civilizational signals (Thought CRs, Message CRs) after simulated work.
		// Best-effort: failures are logged but do not fail the agent.
		behaviorCfg := agent.LoadFlightBehaviorConfig()
		agent.RunFlightBehaviors(ctx, client, cfg, behaviorCfg, task)
	} else {
		workdir := fmt.Sprintf("/workspace/issue-%d", task.IssueNumber)
		logger.Info("executing opencode")
		var execErr error
		result, execErr = agent.ExecuteOpenCode(ctx, prompt, workdir, cfg.Model)
		if execErr != nil {
			return fmt.Errorf("[execute] %w", execErr)
		}

		// Detect PR number (real mode only)
		prNum, prErr := agent.DetectPRNumber(cfg.Repo, task.IssueNumber)
		if prErr != nil {
			logger.Warn("could not detect PR number", "error", prErr)
		} else if prNum > 0 {
			result.PRNumber = prNum
			result.Success = true
			logger.Info("detected PR", "number", prNum)
		}
	}

	// Phase: report
	logger.Info("posting report", "success", result.Success, "pr", result.PRNumber)
	if err := agent.PostReport(ctx, client, cfg.Namespace, cfg.Name, result); err != nil {
		logger.Error("failed to post report", "error", err)
		// Continue to spawn — don't fail the whole agent on report failure
	}

	// Phase: spawn successor
	role, _ := registry.Get(cfg.Role)
	if role != nil && role.Lifecycle.SpawnSuccessor {
		logger.Info("spawning successor", "role", cfg.Role)
		if err := agent.SpawnSuccessor(ctx, client, cfg.Namespace, cfg.Name, cfg.Role); err != nil {
			logger.Error("failed to spawn successor", "error", err)
			// Non-fatal: entrypoint.sh emergency perpetuation handles this
		}
	}

	logger.Info("agent exiting", "success", result.Success)
	return nil
}
