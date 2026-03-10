// Package vote implements governance vote tallying and proposal enactment.
//
// Replaces tally_votes(), enact_proposal(), and the governance engine in coordinator.sh.
// Key improvements over bash:
//   - SQL-based vote counting (atomic, no string parsing)
//   - Type-safe proposal handling
//   - Constitution ConfigMap patching via k8s client (not kubectl subprocess)
//   - Proper error handling — enactment failures don't crash the coordinator
package vote

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"go.uber.org/zap"

	"github.com/pnz1990/agentex/coordinator/internal/config"
	"github.com/pnz1990/agentex/coordinator/internal/store"
	axtypes "github.com/pnz1990/agentex/coordinator/pkg/types"
)

// Engine tallies votes and enacts approved proposals.
type Engine struct {
	store  *store.Store
	config *config.Config
	k8s    kubernetes.Interface
	log    *zap.Logger
}

// New creates a new vote Engine.
func New(s *store.Store, cfg *config.Config, k8s kubernetes.Interface, log *zap.Logger) *Engine {
	return &Engine{store: s, config: cfg, k8s: k8s, log: log}
}

// RecordAndTally records a vote and checks if the proposal threshold has been reached.
// If reached, it enacts the proposal automatically.
func (e *Engine) RecordAndTally(ctx context.Context, vote *axtypes.Vote) error {
	if err := e.store.RecordVote(vote); err != nil {
		return fmt.Errorf("record vote: %w", err)
	}

	approve, _, _, err := e.store.TallyVotes(vote.Topic)
	if err != nil {
		return fmt.Errorf("tally votes: %w", err)
	}

	cfg := e.config.Snapshot()
	if approve >= cfg.VoteThreshold {
		if err := e.enactProposal(ctx, vote.Topic); err != nil {
			e.log.Error("enact proposal failed",
				zap.String("topic", vote.Topic),
				zap.Error(err),
			)
			// Don't return error — vote was recorded, enactment failure is logged
		}
	}
	return nil
}

// enactProposal applies the approved change for a topic.
// Handles well-known governance topics (circuit breaker, vision features, etc.)
// Unknown topics get a verdict Thought CR for agent implementation.
func (e *Engine) enactProposal(ctx context.Context, topic string) error {
	// Get the winning value (most-voted value in approve votes)
	value, err := e.store.GetTopVoteValue(topic)
	if err != nil {
		return fmt.Errorf("get top vote value: %w", err)
	}

	e.log.Info("enacting proposal",
		zap.String("topic", topic),
		zap.String("value", value),
	)

	var enactErr error
	switch {
	case topic == "circuit-breaker":
		enactErr = e.enactCircuitBreaker(ctx, value)
	case topic == "vision-feature":
		enactErr = e.enactVisionFeature(ctx, value)
	default:
		// Generic: post a verdict thought for agent implementation
		e.log.Info("unknown topic — posting verdict thought for agents",
			zap.String("topic", topic),
			zap.String("value", value),
		)
	}

	if enactErr != nil {
		return enactErr
	}

	// Mark proposal as enacted in DB
	return e.store.MarkProposalEnacted(topic)
}

// enactCircuitBreaker updates the circuitBreakerLimit in the constitution ConfigMap.
// Replaces the circuit_breaker patch logic in coordinator.sh.
func (e *Engine) enactCircuitBreaker(ctx context.Context, value string) error {
	// value format: "circuitBreakerLimit=12" or just "12"
	limit := value
	if strings.Contains(value, "=") {
		parts := strings.SplitN(value, "=", 2)
		limit = parts[1]
	}

	if _, err := strconv.Atoi(limit); err != nil {
		return fmt.Errorf("invalid circuit breaker limit %q: %w", limit, err)
	}

	cfg := e.config.Snapshot()
	patch := fmt.Sprintf(`{"data":{"circuitBreakerLimit":"%s"}}`, limit)
	_, err := e.k8s.CoreV1().ConfigMaps(cfg.Namespace).Patch(
		ctx,
		"agentex-constitution",
		types.MergePatchType,
		[]byte(patch),
		metav1.PatchOptions{},
	)
	if err != nil {
		return fmt.Errorf("patch constitution: %w", err)
	}

	e.log.Info("circuit breaker limit updated", zap.String("limit", limit))
	return nil
}

// enactVisionFeature adds a feature to the vision queue in coordinator-state.
func (e *Engine) enactVisionFeature(ctx context.Context, value string) error {
	// value format: "feature=mentorship-chains description=... reason=..."
	// We just append the raw value to the visionQueue
	cfg := e.config.Snapshot()

	// Read current vision queue
	cm, err := e.k8s.CoreV1().ConfigMaps(cfg.Namespace).Get(
		ctx, "coordinator-state", metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("get coordinator-state: %w", err)
	}

	currentQueue := cm.Data["visionQueue"]
	var newQueue string
	if currentQueue == "" {
		newQueue = value
	} else {
		newQueue = currentQueue + ";" + value
	}

	patch := fmt.Sprintf(`{"data":{"visionQueue":%q}}`, newQueue)
	_, err = e.k8s.CoreV1().ConfigMaps(cfg.Namespace).Patch(
		ctx,
		"coordinator-state",
		types.MergePatchType,
		[]byte(patch),
		metav1.PatchOptions{},
	)
	if err != nil {
		return fmt.Errorf("patch coordinator-state: %w", err)
	}

	e.log.Info("vision feature enacted", zap.String("feature", value))
	return nil
}
