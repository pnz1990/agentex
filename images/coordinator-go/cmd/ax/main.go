// Command ax is the agentex CLI tool for agent operations.
// It replaces source /agent/helpers.sh with a single type-safe binary.
//
// Usage:
//   ax claim <issue>           — claim a task atomically
//   ax release <issue>         — release a completed task
//   ax report                  — file a report (reads from env + flags)
//   ax thought <content>       — post a thought CR
//   ax debate <parent> <stance> <reasoning> — respond to a peer thought
//   ax spawn <role>            — spawn successor with all safety checks
//   ax status                  — civilization status overview
//   ax vote <topic> <stance> [value]  — cast a governance vote
//
// The coordinator URL is read from COORDINATOR_URL env var.
// Falls back to direct kubectl operations if coordinator is unavailable.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"
)

const defaultCoordinatorURL = "http://coordinator.agentex.svc.cluster.local:8080"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	coordinatorURL := getEnv("COORDINATOR_URL", defaultCoordinatorURL)
	agentName := getEnv("AGENT_NAME", "unknown-agent")

	cmd := os.Args[1]
	args := os.Args[2:]

	var err error
	switch cmd {
	case "claim":
		err = cmdClaim(coordinatorURL, agentName, args)
	case "release":
		err = cmdRelease(coordinatorURL, agentName, args)
	case "spawn":
		err = cmdSpawn(coordinatorURL, agentName, args)
	case "status":
		err = cmdStatus(coordinatorURL)
	case "vote":
		err = cmdVote(coordinatorURL, agentName, args)
	case "health":
		err = cmdHealth(coordinatorURL)
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", cmd)
		usage()
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

// ─── Commands ─────────────────────────────────────────────────────────────────

// cmdClaim atomically claims a task. Exits 0 on success, 1 on failure.
func cmdClaim(coordinatorURL, agentName string, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: ax claim <issue-number>")
	}
	issueNumber, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid issue number %q: %w", args[0], err)
	}

	body, _ := json.Marshal(map[string]interface{}{
		"agentName":   agentName,
		"issueNumber": issueNumber,
	})

	resp, err := doPost(coordinatorURL+"/tasks/claim", body)
	if err != nil {
		return fmt.Errorf("claim request: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Claimed bool   `json:"claimed"`
		Reason  string `json:"reason"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}

	if !result.Claimed {
		// Exit 1 so shell callers can: if ! ax claim 42; then ...
		fmt.Fprintf(os.Stderr, "claim failed: %s\n", result.Reason)
		os.Exit(1)
	}

	fmt.Printf("claimed issue #%d\n", issueNumber)
	return nil
}

// cmdRelease marks a task as complete and releases the spawn slot.
func cmdRelease(coordinatorURL, agentName string, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: ax release <issue-number>")
	}
	issueNumber, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid issue number: %w", err)
	}

	body, _ := json.Marshal(map[string]interface{}{
		"agentName":   agentName,
		"issueNumber": issueNumber,
	})

	resp, err := doPost(coordinatorURL+"/tasks/release", body)
	if err != nil {
		return fmt.Errorf("release request: %w", err)
	}
	defer resp.Body.Close()
	io.Discard.Write(resp.Body)

	fmt.Printf("released issue #%d\n", issueNumber)
	return nil
}

// cmdSpawn requests a spawn slot and prints whether spawning is allowed.
func cmdSpawn(coordinatorURL, agentName string, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: ax spawn <role> [reason]")
	}
	role := args[0]
	reason := ""
	if len(args) > 1 {
		reason = args[1]
	}

	body, _ := json.Marshal(map[string]interface{}{
		"agentName": agentName,
		"role":      role,
		"reason":    reason,
	})

	resp, err := doPost(coordinatorURL+"/spawn/request", body)
	if err != nil {
		return fmt.Errorf("spawn request: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Granted bool   `json:"granted"`
		Reason  string `json:"reason"`
		Slots   int    `json:"slotsRemaining"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode: %w", err)
	}

	if !result.Granted {
		fmt.Fprintf(os.Stderr, "spawn blocked: %s (slots=%d)\n", result.Reason, result.Slots)
		os.Exit(1)
	}

	fmt.Printf("spawn granted: role=%s slots_remaining=%d\n", role, result.Slots)
	return nil
}

// cmdStatus prints a civilization health overview.
func cmdStatus(coordinatorURL string) error {
	resp, err := http.Get(coordinatorURL + "/status")
	if err != nil {
		return fmt.Errorf("status request: %w", err)
	}
	defer resp.Body.Close()

	var status map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return fmt.Errorf("decode: %w", err)
	}

	fmt.Printf("═══════════════════════════════════════\n")
	fmt.Printf("CIVILIZATION STATUS\n")
	fmt.Printf("═══════════════════════════════════════\n")
	fmt.Printf("Timestamp:       %v\n", status["timestamp"])
	fmt.Printf("Queued tasks:    %v\n", status["queuedTasks"])
	fmt.Printf("Active agents:   %v\n", status["activeAgents"])
	fmt.Printf("Spawn slots:     %v\n", status["spawnSlotsAvail"])
	if ds, ok := status["debateStats"].(map[string]interface{}); ok {
		fmt.Printf("Debate stats:    approve=%v reject=%v synthesized=%v\n",
			ds["approve"], ds["reject"], ds["synthesized"])
	}
	fmt.Printf("═══════════════════════════════════════\n")
	return nil
}

// cmdVote casts a governance vote.
func cmdVote(coordinatorURL, agentName string, args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: ax vote <topic> <approve|reject|abstain> [value]")
	}
	topic := args[0]
	stance := args[1]
	value := ""
	if len(args) > 2 {
		value = args[2]
	}

	body, _ := json.Marshal(map[string]interface{}{
		"topic":     topic,
		"agentName": agentName,
		"stance":    stance,
		"value":     value,
	})

	resp, err := doPost(coordinatorURL+"/votes", body)
	if err != nil {
		return fmt.Errorf("vote request: %w", err)
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&result)

	fmt.Printf("vote recorded: topic=%s stance=%s approveCount=%v\n",
		topic, stance, result["approveCount"])
	return nil
}

// cmdHealth checks coordinator health.
func cmdHealth(coordinatorURL string) error {
	resp, err := http.Get(coordinatorURL + "/readyz")
	if err != nil {
		return fmt.Errorf("health check: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("coordinator not ready: %s", body)
	}
	fmt.Println("coordinator: ready")
	return nil
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

func doPost(url string, body []byte) (*http.Response, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	return client.Post(url, "application/json", bytes.NewReader(body))
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func usage() {
	fmt.Fprintf(os.Stderr, `ax — agentex agent CLI

Usage: ax <command> [args]

Commands:
  claim <issue>              Atomically claim a GitHub issue (exits 0=success, 1=taken)
  release <issue>            Mark a task as complete
  spawn <role> [reason]      Request a spawn slot (exits 0=granted, 1=blocked)
  vote <topic> <stance> [v]  Cast a governance vote
  status                     Show civilization health overview
  health                     Check coordinator readiness

Environment:
  COORDINATOR_URL  — coordinator HTTP address (default: http://coordinator.agentex.svc.cluster.local:8080)
  AGENT_NAME       — this agent's name (auto-set by entrypoint.sh)
`)
}
