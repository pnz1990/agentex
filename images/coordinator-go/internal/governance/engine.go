// Package governance handles vote tallying and consensus enactment.
// It replaces the 900+ line tally_and_enact_votes() bash function with
// type-safe Go code that handles constitution patching via Kubernetes API.
package governance

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"

	"github.com/pnz1990/agentex/coordinator/internal/state"
)

// Engine handles governance vote tallying and proposal enactment.
type Engine struct {
	db           *state.DB
	k8s          kubernetes.Interface
	namespace    string
	voteThreshold int
	logger       *slog.Logger
}

// New creates a new governance engine.
func New(db *state.DB, k8s kubernetes.Interface, namespace string, voteThreshold int, logger *slog.Logger) *Engine {
	return &Engine{
		db:            db,
		k8s:           k8s,
		namespace:     namespace,
		voteThreshold: voteThreshold,
		logger:        logger,
	}
}

// ProposalType represents the kind of governance proposal.
type ProposalType string

const (
	ProposalCircuitBreaker   ProposalType = "circuit-breaker"
	ProposalVoteThreshold    ProposalType = "vote-threshold"
	ProposalVisionScore      ProposalType = "vision-score"
	ProposalJobTTL           ProposalType = "job-ttl"
	ProposalVisionFeature    ProposalType = "vision-feature"
	ProposalVisionQueue      ProposalType = "vision-queue"
	ProposalGeneric          ProposalType = "generic"
)

// Proposal represents a parsed governance proposal.
type Proposal struct {
	Type   ProposalType
	Topic  string
	Params map[string]string
	Raw    string
}

// ParseProposal parses a proposal from a Thought CR content string.
// Format: "#proposal-<topic> key=value key2=value2"
func ParseProposal(content string) (*Proposal, error) {
	lines := strings.Split(content, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "#proposal-") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) == 0 {
			continue
		}
		topic := strings.TrimPrefix(parts[0], "#proposal-")
		params := map[string]string{}
		for _, p := range parts[1:] {
			kv := strings.SplitN(p, "=", 2)
			if len(kv) == 2 {
				params[kv[0]] = kv[1]
			}
		}
		pType := classifyProposal(topic)
		return &Proposal{
			Type:   pType,
			Topic:  topic,
			Params: params,
			Raw:    line,
		}, nil
	}
	return nil, fmt.Errorf("no proposal found in content")
}

func classifyProposal(topic string) ProposalType {
	switch topic {
	case "circuit-breaker":
		return ProposalCircuitBreaker
	case "vote-threshold":
		return ProposalVoteThreshold
	case "vision-score", "minimum-vision-score":
		return ProposalVisionScore
	case "job-ttl":
		return ProposalJobTTL
	case "vision-feature":
		return ProposalVisionFeature
	case "vision-queue":
		return ProposalVisionQueue
	default:
		return ProposalGeneric
	}
}

// TallyAndEnact checks all open proposals and enacts those with sufficient votes.
// Returns the list of topics enacted this cycle.
func (e *Engine) TallyAndEnact(ctx context.Context) ([]string, error) {
	// Get all votes grouped by topic
	topics, err := e.getOpenTopics(ctx)
	if err != nil {
		return nil, fmt.Errorf("get open topics: %w", err)
	}

	var enacted []string
	for _, topic := range topics {
		// Skip already enacted topics
		has, err := e.db.HasDecision(topic)
		if err != nil {
			e.logger.Error("check decision", "topic", topic, "error", err)
			continue
		}
		if has {
			continue
		}

		approveCount, err := e.db.CountApproveVotes(topic)
		if err != nil {
			e.logger.Error("count votes", "topic", topic, "error", err)
			continue
		}

		if approveCount < e.voteThreshold {
			e.logger.Debug("proposal not yet at threshold", "topic", topic, "approves", approveCount, "threshold", e.voteThreshold)
			continue
		}

		// Get winning value (most common approved value)
		votes, err := e.db.GetVotesByTopic(topic)
		if err != nil {
			continue
		}
		value := getMajorityValue(votes)

		if err := e.enact(ctx, topic, value, approveCount); err != nil {
			e.logger.Error("enact proposal", "topic", topic, "error", err)
			continue
		}

		enacted = append(enacted, topic)
		e.logger.Info("proposal enacted", "topic", topic, "value", value, "approves", approveCount)
	}
	return enacted, nil
}

// enact applies a governance decision.
func (e *Engine) enact(ctx context.Context, topic, value string, approveCount int) error {
	proposal := classifyProposal(topic)

	switch proposal {
	case ProposalCircuitBreaker:
		limit, err := strconv.Atoi(value)
		if err != nil {
			return fmt.Errorf("invalid circuitBreakerLimit %q: %w", value, err)
		}
		if err := e.patchConstitution(ctx, "circuitBreakerLimit", value); err != nil {
			return err
		}
		if err := e.db.SetCircuitBreakerLimit(limit); err != nil {
			return err
		}
		e.logger.Info("circuit breaker limit updated", "limit", limit)

	case ProposalVoteThreshold:
		if err := e.patchConstitution(ctx, "voteThreshold", value); err != nil {
			return err
		}
		if n, err := strconv.Atoi(value); err == nil {
			e.voteThreshold = n
		}

	case ProposalVisionScore:
		if err := e.patchConstitution(ctx, "minimumVisionScore", value); err != nil {
			return err
		}

	case ProposalJobTTL:
		if err := e.patchConstitution(ctx, "jobTTLSeconds", value); err != nil {
			return err
		}

	case ProposalVisionFeature, ProposalVisionQueue:
		// Add to visionQueue in coordinator-state
		if err := e.addToVisionQueue(ctx, topic, value); err != nil {
			return err
		}

	default:
		// Generic: post a verdict Thought CR for agents to implement
		e.logger.Info("generic proposal enacted - posting verdict thought", "topic", topic, "value", value)
		if err := e.postVerdictThought(ctx, topic, value, approveCount); err != nil {
			e.logger.Warn("failed to post verdict thought", "error", err)
		}
	}

	// Record the decision
	decision := &state.Decision{
		Topic:        topic,
		EnactedAt:    time.Now().UTC(),
		Value:        value,
		ApproveVotes: approveCount,
		Reason:       fmt.Sprintf("governance vote: %d approvals reached threshold %d", approveCount, e.voteThreshold),
	}
	return e.db.RecordDecision(decision)
}

// patchConstitution patches a key in the agentex-constitution ConfigMap.
func (e *Engine) patchConstitution(ctx context.Context, key, value string) error {
	patch := fmt.Sprintf(`{"data":{%q:%q}}`, key, value)
	_, err := e.k8s.CoreV1().ConfigMaps(e.namespace).Patch(
		ctx,
		"agentex-constitution",
		types.MergePatchType,
		[]byte(patch),
		metav1.PatchOptions{},
	)
	if err != nil {
		return fmt.Errorf("patch constitution %s=%s: %w", key, value, err)
	}
	e.logger.Info("constitution patched", "key", key, "value", value)
	return nil
}

// addToVisionQueue appends a feature to coordinator-state.visionQueue.
func (e *Engine) addToVisionQueue(ctx context.Context, topic, value string) error {
	cm, err := e.k8s.CoreV1().ConfigMaps(e.namespace).Get(ctx, "coordinator-state", metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("get coordinator-state: %w", err)
	}
	existing := cm.Data["visionQueue"]
	var newEntry string
	if value != "" {
		newEntry = value
	} else {
		newEntry = topic
	}
	if existing != "" {
		newEntry = existing + ";" + newEntry
	}

	patch := fmt.Sprintf(`{"data":{"visionQueue":%q}}`, newEntry)
	_, err = e.k8s.CoreV1().ConfigMaps(e.namespace).Patch(
		ctx,
		"coordinator-state",
		types.MergePatchType,
		[]byte(patch),
		metav1.PatchOptions{},
	)
	return err
}

// postVerdictThought posts a Thought CR announcing that a proposal was enacted.
func (e *Engine) postVerdictThought(ctx context.Context, topic, value string, approveCount int) error {
	name := fmt.Sprintf("thought-verdict-%s-%d", strings.ReplaceAll(topic, "-", ""), time.Now().Unix())
	content := fmt.Sprintf(
		"GOVERNANCE VERDICT: #proposal-%s has been enacted with %d approvals.\nValue: %s\nTopic: %s",
		topic, approveCount, value, topic,
	)

	cm := newThoughtConfigMap(name, e.namespace, "coordinator", content)
	_, err := e.k8s.CoreV1().ConfigMaps(e.namespace).Create(ctx, cm, metav1.CreateOptions{})
	return err
}

// getOpenTopics returns all topics that have at least one vote.
func (e *Engine) getOpenTopics(ctx context.Context) ([]string, error) {
	// In production, we'd query the DB for distinct topics with votes
	// For now, we also scan Thought CRs for new proposals
	thoughts, err := e.k8s.CoreV1().ConfigMaps(e.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "agentex/thought=true",
	})
	if err != nil {
		return nil, err
	}

	seen := map[string]bool{}
	var topics []string
	for _, cm := range thoughts.Items {
		if cm.Data["thoughtType"] != "proposal" && cm.Data["thoughtType"] != "vote" {
			continue
		}
		content := cm.Data["content"]
		p, err := ParseProposal(content)
		if err != nil {
			// Try vote parsing
			p = parseVoteTopic(content)
		}
		if p == nil {
			continue
		}

		// Also ingest the vote into our DB
		if cm.Data["thoughtType"] == "vote" {
			if err := e.ingestVote(p.Topic, cm.Data["agentRef"], content); err != nil {
				e.logger.Warn("ingest vote", "error", err)
			}
		}

		if !seen[p.Topic] {
			seen[p.Topic] = true
			topics = append(topics, p.Topic)
		}
	}
	return topics, nil
}

// ingestVote parses and stores a vote from a Thought CR.
func (e *Engine) ingestVote(topic, agentName, content string) error {
	vote := &state.Vote{
		Topic:     topic,
		AgentName: agentName,
	}
	// Parse stance and value from content
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#vote-") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				vote.Stance = parts[1] // approve/reject/abstain
			}
			for _, p := range parts[2:] {
				if kv := strings.SplitN(p, "=", 2); len(kv) == 2 {
					vote.Value = kv[1]
				}
			}
		}
		if strings.HasPrefix(line, "reason:") {
			vote.Reason = strings.TrimPrefix(line, "reason:")
			vote.Reason = strings.TrimSpace(vote.Reason)
		}
	}
	if vote.Stance == "" {
		return nil // no vote found
	}
	return e.db.RecordVote(vote)
}

// parseVoteTopic extracts the topic from a vote Thought content.
func parseVoteTopic(content string) *Proposal {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "#vote-") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) == 0 {
			continue
		}
		topic := strings.TrimPrefix(parts[0], "#vote-")
		return &Proposal{Topic: topic, Type: classifyProposal(topic)}
	}
	return nil
}

// getMajorityValue returns the most common value among approve votes.
func getMajorityValue(votes []state.Vote) string {
	counts := map[string]int{}
	for _, v := range votes {
		if v.Stance == "approve" && v.Value != "" {
			counts[v.Value]++
		}
	}
	best, bestCount := "", 0
	for val, count := range counts {
		if count > bestCount {
			best, bestCount = val, count
		}
	}
	return best
}

// newThoughtConfigMap creates a ConfigMap representing a Thought CR.
func newThoughtConfigMap(name, namespace, agentRef, content string) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Labels: map[string]string{
				"agentex/thought": "true",
			},
		},
		Data: map[string]string{
			"agentRef":    agentRef,
			"taskRef":     "coordinator",
			"thoughtType": "verdict",
			"confidence":  "9",
			"content":     content,
		},
	}
}
