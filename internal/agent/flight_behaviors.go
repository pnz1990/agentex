package agent

// flight_behaviors.go — civilizational behaviors for flight test / mock mode.
//
// When AGENTEX_FLIGHT_TEST=true the agent skips git clone and OpenCode but
// still exercises the Kubernetes coordination layer. This file adds the
// next layer: posting Thought CRs and Message CRs so scenario tests can
// assert on the full civilizational signal pipeline.
//
// All behavior is controlled by env vars (see FlightBehaviorConfig) and
// all actions are best-effort — a failure to post a Thought or Message is
// logged but does not fail the agent. The coordinator lifecycle (Report CR,
// spawn successor) is more important than the optional signals.

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/pnz1990/agentex/internal/k8s"
)

// thoughtTypes enumerates the Thought CR thoughtType values used in flight tests.
// The set mirrors the types used by real agents in helpers.sh (post_thought()).
var thoughtTypes = []string{
	"insight",
	"observation",
	"concern",
	"proposal",
}

// FlightBehaviorConfig controls which civilizational signals the mock agent
// emits. All fields are populated from env vars by LoadFlightBehaviorConfig().
type FlightBehaviorConfig struct {
	// ThoughtCount is the number of Thought CRs to post (FLIGHT_THOUGHT_COUNT, default 2).
	ThoughtCount int
	// DebateEnabled causes the mock agent to post a second Thought of type "vote"
	// in response to a peer, exercising the debate signal path (FLIGHT_DEBATE_ENABLED).
	DebateEnabled bool
	// MessageEnabled causes the mock agent to post a Message CR (FLIGHT_MESSAGE_ENABLED).
	MessageEnabled bool
	// MessageTarget is the recipient of the Message CR. Defaults to "broadcast"
	// (FLIGHT_MESSAGE_TARGET).
	MessageTarget string
}

// LoadFlightBehaviorConfig reads FlightBehaviorConfig from environment variables.
func LoadFlightBehaviorConfig() *FlightBehaviorConfig {
	cfg := &FlightBehaviorConfig{
		ThoughtCount:   2,
		DebateEnabled:  false,
		MessageEnabled: false,
		MessageTarget:  "broadcast",
	}

	if s := os.Getenv("FLIGHT_THOUGHT_COUNT"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n >= 0 {
			cfg.ThoughtCount = n
		}
	}
	if os.Getenv("FLIGHT_DEBATE_ENABLED") == "true" {
		cfg.DebateEnabled = true
	}
	if os.Getenv("FLIGHT_MESSAGE_ENABLED") == "true" {
		cfg.MessageEnabled = true
	}
	if t := os.Getenv("FLIGHT_MESSAGE_TARGET"); t != "" {
		cfg.MessageTarget = t
	}
	return cfg
}

// RunFlightBehaviors executes all enabled civilizational behaviors for a mock agent.
// It is called after ExecuteFlightTest (after the simulated work sleep) and before
// PostReport. Failures are logged but never propagate — the lifecycle must continue.
func RunFlightBehaviors(ctx context.Context, client *k8s.Client, agentCfg *AgentConfig, behaviorCfg *FlightBehaviorConfig, task *TaskInfo) {
	slog.Info("flight behaviors: starting",
		"thoughts", behaviorCfg.ThoughtCount,
		"debate", behaviorCfg.DebateEnabled,
		"message", behaviorCfg.MessageEnabled,
	)

	// 1. Post Thought CRs
	for i := range behaviorCfg.ThoughtCount {
		thoughtType := thoughtTypes[i%len(thoughtTypes)]
		content := flightThoughtContent(agentCfg.Name, agentCfg.Role, task, i, thoughtType)
		if err := PostThought(ctx, client, agentCfg.Namespace, agentCfg.Name, agentCfg.TaskCRName, thoughtType, content); err != nil {
			slog.Warn("flight behaviors: failed to post thought", "index", i, "error", err)
		}
	}

	// 2. Debate response (extra Thought of type "vote" referencing a peer thought)
	if behaviorCfg.DebateEnabled {
		content := fmt.Sprintf(
			"flight-test debate response from %s on issue #%d: "+
				"analysis complete, stance=approve, confidence=8",
			agentCfg.Name, task.IssueNumber,
		)
		if err := PostThought(ctx, client, agentCfg.Namespace, agentCfg.Name, agentCfg.TaskCRName, "vote", content); err != nil {
			slog.Warn("flight behaviors: failed to post debate thought", "error", err)
		}
	}

	// 3. Message CR
	if behaviorCfg.MessageEnabled {
		body := fmt.Sprintf(
			"flight-test status from %s (role=%s): completed issue #%d — %s",
			agentCfg.Name, agentCfg.Role, task.IssueNumber, task.Title,
		)
		if err := PostMessage(ctx, client, agentCfg.Namespace, agentCfg.Name, behaviorCfg.MessageTarget, body); err != nil {
			slog.Warn("flight behaviors: failed to post message", "error", err)
		}
	}

	slog.Info("flight behaviors: complete")
}

// PostThought creates a Thought CR (kro.run/v1alpha1) in the given namespace.
// thoughtType should be one of: insight, observation, concern, proposal, vote, blocker.
// Returns an error if the API call fails; callers should treat this as non-fatal.
func PostThought(ctx context.Context, client *k8s.Client, namespace, agentName, taskRef, thoughtType, content string) error {
	name := fmt.Sprintf("thought-%s-%s-%d", agentName, thoughtType, time.Now().UnixNano())
	// Kubernetes resource names must be <= 253 chars and DNS-label safe.
	if len(name) > 253 {
		name = name[:253]
	}

	obj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8s.KroGroup + "/" + k8s.KroVersion,
			"kind":       "Thought",
			"metadata": map[string]interface{}{
				"name":      name,
				"namespace": namespace,
				"labels": map[string]interface{}{
					"agentex/agent":  agentName,
					"agentex/e2e":    "true",
					"agentex/type":   thoughtType,
					"agentex/flight": "true",
				},
			},
			"spec": map[string]interface{}{
				"agentRef":    agentName,
				"taskRef":     taskRef,
				"content":     content,
				"thoughtType": thoughtType,
				"confidence":  int64(7),
				"topic":       "flight-test",
			},
		},
	}

	if _, err := client.CreateCR(ctx, namespace, k8s.ThoughtGVR, obj); err != nil {
		return fmt.Errorf("creating thought CR %s: %w", name, err)
	}

	slog.Info("posted thought", "name", name, "type", thoughtType)
	return nil
}

// PostMessage creates a Message CR (kro.run/v1alpha1) in the given namespace.
// to can be an agent name, "broadcast", or "swarm:<name>".
// Returns an error if the API call fails; callers should treat this as non-fatal.
func PostMessage(ctx context.Context, client *k8s.Client, namespace, from, to, body string) error {
	name := fmt.Sprintf("msg-%s-%d", from, time.Now().UnixNano())
	if len(name) > 253 {
		name = name[:253]
	}

	obj := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": k8s.KroGroup + "/" + k8s.KroVersion,
			"kind":       "Message",
			"metadata": map[string]interface{}{
				"name":      name,
				"namespace": namespace,
				"labels": map[string]interface{}{
					"agentex/from":   from,
					"agentex/to":     to,
					"agentex/e2e":    "true",
					"agentex/flight": "true",
				},
			},
			"spec": map[string]interface{}{
				"from":        from,
				"to":          to,
				"body":        body,
				"messageType": "status",
			},
		},
	}

	if _, err := client.CreateCR(ctx, namespace, k8s.MessageGVR, obj); err != nil {
		return fmt.Errorf("creating message CR %s: %w", name, err)
	}

	slog.Info("posted message", "name", name, "from", from, "to", to)
	return nil
}

// flightThoughtContent generates varied but deterministic thought content for
// flight tests, indexed by position so each thought in a run is distinct.
func flightThoughtContent(agentName, role string, task *TaskInfo, index int, thoughtType string) string {
	templates := []string{
		"flight-test %s from %s (role=%s): analyzed issue #%d — %s. Proceeding with implementation.",
		"flight-test %s from %s (role=%s): progress update on issue #%d — %s. Patterns identified, approach validated.",
		"flight-test %s from %s (role=%s): checkpoint for issue #%d — %s. No blockers detected, continuing.",
		"flight-test %s from %s (role=%s): completed analysis of issue #%d — %s. Ready for review.",
	}
	tmpl := templates[index%len(templates)]
	return fmt.Sprintf(tmpl, thoughtType, agentName, role, task.IssueNumber, task.Title)
}
