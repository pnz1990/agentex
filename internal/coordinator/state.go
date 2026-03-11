// Package coordinator implements the agentex coordinator — the civilization's
// persistent brain that maintains task queues, tracks agent assignments,
// reconciles spawn slots, and tallies governance votes.
package coordinator

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	k8sclient "github.com/pnz1990/agentex/internal/k8s"
)

// StateConfigMapName is the name of the coordinator state ConfigMap.
const StateConfigMapName = "coordinator-state"

// maxConflictRetries is the maximum number of retries on optimistic concurrency conflict.
const maxConflictRetries = 5

// CoordinatorState holds the typed representation of the coordinator-state ConfigMap.
// All runtime state managed by the coordinator lives here. kro creates the ConfigMap
// with only a "bootstrapped" field; all dynamic fields are managed by the coordinator.
type CoordinatorState struct {
	// TaskQueue is the ordered list of GitHub issue numbers to be worked on.
	// Vision-voted issues appear first, then sorted by vision priority score descending.
	TaskQueue []int

	// ActiveAssignments maps agent name to the issue number they're working on.
	// Format in ConfigMap: "agent1:123,agent2:456"
	ActiveAssignments map[string]int

	// SpawnSlots is the number of available spawn slots (circuitBreakerLimit - activeJobs).
	// Must always be >= 0. Negative values freeze civilization (issue #1240).
	SpawnSlots int

	// VisionQueue holds agent-voted goal entries (issue numbers and feature descriptions).
	// Format in ConfigMap: semicolon-separated entries.
	VisionQueue []string

	// LastHeartbeat is the timestamp of the coordinator's last heartbeat.
	LastHeartbeat time.Time

	// ActiveAgents is the list of currently active agent names with their roles.
	// Format in ConfigMap: "agent1:worker,agent2:planner"
	ActiveAgents []string

	// DecisionLog is the audit trail of coordinator decisions.
	DecisionLog string

	// EnactedDecisions tracks governance decisions that have been enacted.
	EnactedDecisions string

	// ResourceVersion is the Kubernetes resource version for optimistic concurrency.
	// Must be set before calling Save() to prevent lost updates.
	ResourceVersion string
}

// StateManager handles loading and saving coordinator state from/to the
// coordinator-state ConfigMap with optimistic concurrency control.
type StateManager struct {
	client    *k8sclient.Client
	namespace string
	logger    *slog.Logger
}

// NewStateManager creates a new StateManager.
func NewStateManager(client *k8sclient.Client, namespace string, logger *slog.Logger) *StateManager {
	return &StateManager{
		client:    client,
		namespace: namespace,
		logger:    logger,
	}
}

// Load reads the coordinator-state ConfigMap and parses it into a CoordinatorState.
func (sm *StateManager) Load(ctx context.Context) (*CoordinatorState, error) {
	cm, err := sm.client.GetConfigMap(ctx, sm.namespace, StateConfigMapName)
	if err != nil {
		return nil, fmt.Errorf("loading coordinator state: %w", err)
	}

	state := parseState(cm)
	return state, nil
}

// Save writes the CoordinatorState back to the ConfigMap using the stored
// ResourceVersion for optimistic concurrency control. Returns a conflict error
// if the ConfigMap was modified between Load and Save.
func (sm *StateManager) Save(ctx context.Context, state *CoordinatorState) error {
	if state.ResourceVersion == "" {
		return fmt.Errorf("cannot save state without ResourceVersion (must Load first)")
	}

	cm := serializeState(state, sm.namespace)
	_, err := sm.client.UpdateConfigMap(ctx, sm.namespace, cm)
	if err != nil {
		return fmt.Errorf("saving coordinator state: %w", err)
	}
	return nil
}

// UpdateField atomically updates a single field in the coordinator-state ConfigMap
// using a patch. This is the preferred method for single-field updates since it
// avoids read-modify-write races on unrelated fields.
func (sm *StateManager) UpdateField(ctx context.Context, field, value string) error {
	patch := map[string]interface{}{
		"data": map[string]string{
			field: value,
		},
	}
	patchBytes, err := json.Marshal(patch)
	if err != nil {
		return fmt.Errorf("marshaling patch for field %s: %w", field, err)
	}

	_, err = sm.client.PatchConfigMap(ctx, sm.namespace, StateConfigMapName, patchBytes)
	if err != nil {
		return fmt.Errorf("patching field %s: %w", field, err)
	}
	return nil
}

// GetField reads a single field from the coordinator-state ConfigMap.
func (sm *StateManager) GetField(ctx context.Context, field string) (string, error) {
	cm, err := sm.client.GetConfigMap(ctx, sm.namespace, StateConfigMapName)
	if err != nil {
		return "", fmt.Errorf("getting field %s: %w", field, err)
	}
	return cm.Data[field], nil
}

// UpdateWithRetry performs a read-modify-write cycle on the coordinator state,
// retrying on conflict up to maxConflictRetries times. The mutator function
// receives the current state and should modify it in place. The modified state
// is then written back with optimistic concurrency.
func (sm *StateManager) UpdateWithRetry(ctx context.Context, mutator func(*CoordinatorState) error) error {
	for attempt := range maxConflictRetries {
		state, err := sm.Load(ctx)
		if err != nil {
			return fmt.Errorf("loading state for update (attempt %d): %w", attempt+1, err)
		}

		if err := mutator(state); err != nil {
			return fmt.Errorf("mutating state (attempt %d): %w", attempt+1, err)
		}

		err = sm.Save(ctx, state)
		if err == nil {
			return nil
		}

		if k8sclient.IsConflict(err) {
			sm.logger.Warn("conflict on state update, retrying",
				"attempt", attempt+1,
				"maxRetries", maxConflictRetries,
			)
			// Brief sleep with exponential backoff before retry
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(50*(1<<attempt)) * time.Millisecond):
			}
			continue
		}

		return err
	}
	return fmt.Errorf("state update failed after %d conflict retries", maxConflictRetries)
}

// parseState converts a ConfigMap into a CoordinatorState struct.
func parseState(cm *corev1.ConfigMap) *CoordinatorState {
	data := cm.Data
	if data == nil {
		data = make(map[string]string)
	}

	state := &CoordinatorState{
		ResourceVersion: cm.ResourceVersion,
	}

	// Parse TaskQueue: comma-separated integers
	state.TaskQueue = parseIntList(data["taskQueue"])

	// Parse ActiveAssignments: "agent1:123,agent2:456"
	state.ActiveAssignments = parseAssignments(data["activeAssignments"])

	// Parse SpawnSlots
	state.SpawnSlots = parseIntDefault(data["spawnSlots"], 0)

	// Parse VisionQueue: semicolon-separated entries
	state.VisionQueue = parseSemicolonList(data["visionQueue"])

	// Parse LastHeartbeat
	if ts := data["lastHeartbeat"]; ts != "" {
		t, err := time.Parse(time.RFC3339, ts)
		if err == nil {
			state.LastHeartbeat = t
		}
	}

	// Parse ActiveAgents: comma-separated "name:role" pairs
	if agents := data["activeAgents"]; agents != "" {
		for _, entry := range strings.Split(agents, ",") {
			entry = strings.TrimSpace(entry)
			if entry != "" {
				state.ActiveAgents = append(state.ActiveAgents, entry)
			}
		}
	}

	state.DecisionLog = data["decisionLog"]
	state.EnactedDecisions = data["enactedDecisions"]

	return state
}

// serializeState converts a CoordinatorState into a ConfigMap for writing.
func serializeState(state *CoordinatorState, namespace string) *corev1.ConfigMap {
	data := make(map[string]string)

	// Serialize TaskQueue
	data["taskQueue"] = formatIntList(state.TaskQueue)

	// Serialize ActiveAssignments
	data["activeAssignments"] = formatAssignments(state.ActiveAssignments)

	// Serialize SpawnSlots
	data["spawnSlots"] = strconv.Itoa(state.SpawnSlots)

	// Serialize VisionQueue
	data["visionQueue"] = strings.Join(state.VisionQueue, ";")

	// Serialize LastHeartbeat
	if !state.LastHeartbeat.IsZero() {
		data["lastHeartbeat"] = state.LastHeartbeat.UTC().Format(time.RFC3339)
	}

	// Serialize ActiveAgents
	data["activeAgents"] = strings.Join(state.ActiveAgents, ",")

	// Preserve string fields
	data["decisionLog"] = state.DecisionLog
	data["enactedDecisions"] = state.EnactedDecisions

	// Preserve the bootstrapped field that kro manages
	data["bootstrapped"] = "true"

	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       namespace,
			ResourceVersion: state.ResourceVersion,
			Labels: map[string]string{
				"agentex/component": "coordinator",
			},
		},
		Data: data,
	}
	return cm
}

// parseIntList splits a comma-separated string into a slice of ints,
// silently skipping non-numeric entries.
func parseIntList(s string) []int {
	if s == "" {
		return nil
	}
	var result []int
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if n, err := strconv.Atoi(part); err == nil {
			result = append(result, n)
		}
	}
	return result
}

// formatIntList formats a slice of ints as a comma-separated string.
func formatIntList(nums []int) string {
	parts := make([]string, len(nums))
	for i, n := range nums {
		parts[i] = strconv.Itoa(n)
	}
	return strings.Join(parts, ",")
}

// parseAssignments parses "agent1:123,agent2:456" into a map.
func parseAssignments(s string) map[string]int {
	result := make(map[string]int)
	if s == "" {
		return result
	}
	for _, pair := range strings.Split(s, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		parts := strings.SplitN(pair, ":", 2)
		if len(parts) != 2 {
			continue
		}
		agent := strings.TrimSpace(parts[0])
		issue, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || agent == "" {
			continue
		}
		result[agent] = issue
	}
	return result
}

// formatAssignments formats a map as "agent1:123,agent2:456".
func formatAssignments(m map[string]int) string {
	if len(m) == 0 {
		return ""
	}
	parts := make([]string, 0, len(m))
	for agent, issue := range m {
		parts = append(parts, fmt.Sprintf("%s:%d", agent, issue))
	}
	return strings.Join(parts, ",")
}

// parseSemicolonList splits a semicolon-separated string into a slice,
// trimming whitespace and skipping empty entries.
func parseSemicolonList(s string) []string {
	if s == "" {
		return nil
	}
	var result []string
	for _, part := range strings.Split(s, ";") {
		part = strings.TrimSpace(part)
		if part != "" {
			result = append(result, part)
		}
	}
	return result
}

// parseIntDefault parses a string as an integer, returning defaultVal on failure.
func parseIntDefault(s string, defaultVal int) int {
	if s == "" {
		return defaultVal
	}
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return defaultVal
	}
	return n
}
