package coordinator

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync/atomic"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/pnz1990/agentex/internal/audit"
	"github.com/pnz1990/agentex/internal/config"
	"github.com/pnz1990/agentex/internal/health"
	k8sclient "github.com/pnz1990/agentex/internal/k8s"
)

// Coordinator is the agentex civilization's persistent brain. It runs as a
// long-lived process that maintains the canonical task queue, tracks agent
// assignments, reconciles spawn slots, and tallies governance votes.
type Coordinator struct {
	client        *k8sclient.Client
	namespace     string
	config        *config.Config
	stateManager  *StateManager
	githubFetcher GitHubIssueFetcher
	logger        *slog.Logger
	stopCh        chan struct{}
	running       atomic.Bool
	metrics       *Metrics
	healthMonitor *health.Monitor

	// Completion tracking for coordinator-controlled spawning (#2061)
	tracker                  *completionTracker
	coordinatorSpawnsEnabled bool

	// Audit logger for durable action trail (#2062)
	auditLog *audit.Logger
}

// NewCoordinator creates a new Coordinator instance.
func NewCoordinator(client *k8sclient.Client, cfg *config.Config, logger *slog.Logger) *Coordinator {
	return &Coordinator{
		client:        client,
		namespace:     cfg.Namespace,
		config:        cfg,
		stateManager:  NewStateManager(client, cfg.Namespace, logger),
		githubFetcher: newHTTPGitHubFetcher(logger),
		logger:        logger,
		stopCh:        make(chan struct{}),
		tracker:       newCompletionTracker(),
	}
}

// WithMetrics attaches a Metrics instance to the coordinator so the tick loop
// increments Prometheus-compatible metrics on every reconciliation cycle.
func (c *Coordinator) WithMetrics(m *Metrics) *Coordinator {
	c.metrics = m
	return c
}

// WithHealthMonitor attaches a health.Monitor that is started alongside the
// coordinator main loop and stopped when the coordinator stops.
func (c *Coordinator) WithHealthMonitor(m *health.Monitor) *Coordinator {
	c.healthMonitor = m
	return c
}

// WithAuditLogger attaches a durable audit logger (#2062).
// If set, the coordinator logs dispatch, spawn, kill, and remediation decisions.
func (c *Coordinator) WithAuditLogger(l *audit.Logger) *Coordinator {
	c.auditLog = l
	return c
}

// Run starts the coordinator main loop. It blocks until ctx is cancelled or
// Stop is called. The main loop is tick-based, matching the bash coordinator:
//
//	Every tick:          heartbeat, cleanup stale assignments, dispatch next task
//	Every 3 ticks:       tally governance votes
//	Every 4 ticks:       reconcile spawn slots, cleanup active agents
//	Every 5 ticks:       refresh task queue
//	Every 10 ticks:      ensure state fields initialized, cleanup orphaned pods
//
// Each tick interval is config.HeartbeatInterval (default 30s).
func (c *Coordinator) Run(ctx context.Context) error {
	c.logger.Info("coordinator starting",
		"namespace", c.namespace,
		"heartbeatInterval", c.config.HeartbeatInterval,
	)

	// Load constitution on startup
	if err := c.loadConstitution(ctx); err != nil {
		return fmt.Errorf("loading constitution: %w", err)
	}

	// Start watching constitution for live updates
	c.config.WatchConstitution(ctx, c.client.Clientset)

	// Initialize state fields (like the bash coordinator's ensure_state_fields_initialized)
	if err := c.ensureStateFieldsInitialized(ctx); err != nil {
		c.logger.Error("failed to initialize state fields", "error", err)
		// Non-fatal — continue running, periodic re-init will fix it
	}

	// Early spawn slot reconciliation (issue #1581) — before entering the main loop.
	if err := c.reconcileSpawnSlots(ctx); err != nil {
		c.logger.Error("early spawn slot reconciliation failed", "error", err)
	}

	// Read coordinator-spawns feature flag (#2061 Phase 2)
	c.refreshCoordinatorSpawnsFlag(ctx)

	// Start health monitor if configured (#2059)
	if c.healthMonitor != nil {
		go c.healthMonitor.Run(ctx)
		c.logger.Info("health monitor started")
	}

	// Start audit logger if configured (#2062)
	if c.auditLog != nil {
		go c.auditLog.Start(ctx)
		c.logger.Info("audit logger started")
	}

	ticker := time.NewTicker(c.config.HeartbeatInterval)
	defer ticker.Stop()

	iteration := 0
	c.logger.Info("entering main loop")
	c.running.Store(true)

	for {
		select {
		case <-ctx.Done():
			c.logger.Info("context cancelled, shutting down")
			return ctx.Err()
		case <-c.stopCh:
			c.logger.Info("stop requested, shutting down")
			return nil
		case <-ticker.C:
			iteration++
			c.tick(ctx, iteration)
		}
	}
}

// tick executes one iteration of the coordinator main loop.
func (c *Coordinator) tick(ctx context.Context, iteration int) {
	start := time.Now()
	c.logger.Debug("tick", "iteration", iteration)

	// --- metrics: count this reconcile cycle (#2058) ---
	if c.metrics != nil {
		c.metrics.ReconcileTotal.Inc()
	}

	tickErr := false

	// Every tick: heartbeat
	if err := c.heartbeat(ctx); err != nil {
		c.logger.Error("heartbeat failed", "error", err)
		tickErr = true
	}

	// Every tick: touch liveness probe file (K8s exec probe compatibility)
	c.touchLivenessFile()

	// Every tick: cleanup stale assignments
	if err := c.cleanupStaleAssignments(ctx); err != nil {
		c.logger.Error("cleanup stale assignments failed", "error", err)
		tickErr = true
	}

	// Every tick: dispatch next task to a waiting agent (#2057)
	if err := c.dispatchNextTask(ctx); err != nil {
		c.logger.Error("dispatch next task failed", "error", err)
		tickErr = true
	}

	// Every 2 ticks: handle completed agents and optionally respawn (#2061)
	if iteration%2 == 0 {
		if err := c.handleCompletedAgents(ctx); err != nil {
			c.logger.Error("handle completed agents failed", "error", err)
			tickErr = true
		}
	}

	// Every 3 ticks: tally governance votes
	if iteration%3 == 0 {
		if err := c.tallyGovernanceVotes(ctx); err != nil {
			c.logger.Error("governance vote tally failed", "error", err)
			tickErr = true
		}
	}

	// Every 4 ticks: reconcile spawn slots + cleanup active agents + remediate
	if iteration%4 == 0 {
		if err := c.reconcileSpawnSlots(ctx); err != nil {
			c.logger.Error("spawn slot reconciliation failed", "error", err)
			tickErr = true
		}
		if err := c.cleanupActiveAgents(ctx); err != nil {
			c.logger.Error("cleanup active agents failed", "error", err)
			tickErr = true
		}
		if err := c.runRemediation(ctx); err != nil {
			c.logger.Error("remediation cycle failed", "error", err)
			tickErr = true
		}
	}

	// Every 5 ticks: refresh task queue from GitHub
	if iteration%5 == 0 {
		if err := c.refreshTaskQueue(ctx); err != nil {
			c.logger.Error("task queue refresh failed", "error", err)
			tickErr = true
		}
	}

	// Every 10 ticks: periodic state field initialization + orphaned pod cleanup
	if iteration%10 == 0 {
		if err := c.ensureStateFieldsInitialized(ctx); err != nil {
			c.logger.Error("state field initialization failed", "error", err)
			tickErr = true
		}
	}

	// Adaptive spawn slot reconciliation: also check every tick for negative/false-zero
	if iteration%4 != 0 { // Skip if we already reconciled this tick
		if err := c.checkSpawnSlotAnomaly(ctx); err != nil {
			c.logger.Error("spawn slot anomaly check failed", "error", err)
		}
	}

	// --- metrics: record duration and error count (#2058) ---
	if c.metrics != nil {
		elapsed := time.Since(start).Seconds()
		c.metrics.ReconcileDuration.Set(elapsed)
		if tickErr {
			c.metrics.ReconcileErrors.Inc()
		}

		// Snapshot kill switch state
		if ks, _, err := c.IsKillSwitchActive(ctx); err == nil {
			if ks {
				c.metrics.KillSwitchActive.Set(1)
			} else {
				c.metrics.KillSwitchActive.Set(0)
			}
		}

		// Snapshot spawn slots
		if slotsStr, err := c.stateManager.GetField(ctx, "spawnSlots"); err == nil {
			slots := float64(parseIntDefault(slotsStr, 0))
			c.metrics.SpawnSlots.Set(slots)
		}

		// Snapshot circuit breaker limit
		constitution := c.config.GetConstitution()
		c.metrics.CircuitBreakerLimit.Set(float64(constitution.CircuitBreakerLimit))
	}
}

// Stop signals the coordinator to shut down gracefully.
func (c *Coordinator) Stop() {
	c.logger.Info("stop signal received")
	c.running.Store(false)
	close(c.stopCh)
}

// IsRunning returns true if the coordinator main loop is active.
func (c *Coordinator) IsRunning() bool {
	return c.running.Load()
}

// loadConstitution reads the agentex-constitution ConfigMap and loads it into config.
func (c *Coordinator) loadConstitution(ctx context.Context) error {
	cm, err := c.client.GetConfigMap(ctx, c.namespace, config.ConstitutionConfigMapName)
	if err != nil {
		return err
	}
	return c.config.LoadFromConfigMap(cm)
}

// heartbeat writes the current timestamp to the coordinator-state ConfigMap.
func (c *Coordinator) heartbeat(ctx context.Context) error {
	now := time.Now().UTC().Format(time.RFC3339)
	return c.stateManager.UpdateField(ctx, "lastHeartbeat", now)
}

// touchLivenessFile writes /tmp/coordinator-alive for K8s exec-based
// liveness probes. The coordinator-graph RGD uses an exec probe that
// checks for this file. This ensures compatibility whether running
// the bash or Go coordinator.
func (c *Coordinator) touchLivenessFile() {
	if err := os.WriteFile("/tmp/coordinator-alive", []byte(time.Now().UTC().Format(time.RFC3339)), 0o644); err != nil {
		c.logger.Warn("failed to touch liveness file", "error", err)
	}
}

// ensureStateFieldsInitialized initializes coordinator-state fields that may
// be missing. This handles fields added after the coordinator was last restarted.
// Matches the bash coordinator's ensure_state_fields_initialized().
func (c *Coordinator) ensureStateFieldsInitialized(ctx context.Context) error {
	cm, err := c.client.GetConfigMap(ctx, c.namespace, StateConfigMapName)
	if err != nil {
		return err
	}

	if cm.Data == nil {
		cm.Data = make(map[string]string)
	}

	// Fields that should exist with empty string defaults
	emptyDefaults := []string{
		"activeAgents", "activeAssignments", "decisionLog",
		"enactedDecisions", "visionQueue", "visionQueueLog",
		"lastTallyTimestamp", "preClaimTimestamps", "chronicleCandidates",
		"agentTrustGraph", "v05MilestoneStatus", "v05CriteriaStatus",
		"v06MilestoneStatus", "v06CriteriaStatus", "activeSwarms",
		"lastSpecializedRouting", "lastRoutingDecisions", "issueLabels",
	}

	// Fields that should default to "0"
	zeroDefaults := []string{
		"specializedAssignments", "genericAssignments",
		"routingCyclesWithZeroSpec",
	}

	needsPatch := false
	patchData := make(map[string]string)

	for _, field := range emptyDefaults {
		if _, exists := cm.Data[field]; !exists {
			patchData[field] = ""
			needsPatch = true
			c.logger.Info("initializing state field", "field", field, "default", "")
		}
	}

	for _, field := range zeroDefaults {
		if _, exists := cm.Data[field]; !exists {
			patchData[field] = "0"
			needsPatch = true
			c.logger.Info("initializing state field", "field", field, "default", "0")
		}
	}

	// spawnSlots: ensure it's a valid non-negative integer (issue #1240)
	if val, exists := cm.Data["spawnSlots"]; !exists || !isValidNonNegativeInt(val) {
		patchData["spawnSlots"] = "0"
		needsPatch = true
		c.logger.Warn("spawnSlots invalid, resetting to 0", "currentValue", val)
	}

	if needsPatch {
		return c.stateManager.patchFields(ctx, patchData)
	}
	return nil
}

// patchFields patches multiple fields in the coordinator-state ConfigMap at once.
func (sm *StateManager) patchFields(ctx context.Context, fields map[string]string) error {
	for field, value := range fields {
		if err := sm.UpdateField(ctx, field, value); err != nil {
			return fmt.Errorf("initializing field %s: %w", field, err)
		}
	}
	return nil
}

// reconcileSpawnSlots recalculates spawn slots based on active jobs and the
// circuit breaker limit. This is the ground-truth reconciliation that
// corrects any drift in the spawnSlots field.
func (c *Coordinator) reconcileSpawnSlots(ctx context.Context) error {
	constitution := c.config.GetConstitution()
	limit := constitution.CircuitBreakerLimit

	activeJobs, err := c.client.CountActiveJobs(ctx, c.namespace)
	if err != nil {
		return fmt.Errorf("counting active jobs: %w", err)
	}

	correctSlots := limit - activeJobs
	if correctSlots < 0 {
		correctSlots = 0
	}

	currentSlots, err := c.stateManager.GetField(ctx, "spawnSlots")
	if err != nil {
		return err
	}

	c.logger.Info("spawn slot reconciliation",
		"limit", limit,
		"activeJobs", activeJobs,
		"currentSlots", currentSlots,
		"correctSlots", correctSlots,
	)

	if currentSlots != fmt.Sprintf("%d", correctSlots) {
		if err := c.stateManager.UpdateField(ctx, "spawnSlots", fmt.Sprintf("%d", correctSlots)); err != nil {
			return err
		}
		c.logger.Info("reconciled spawn slots",
			"from", currentSlots,
			"to", correctSlots,
		)
	}

	return nil
}

// checkSpawnSlotAnomaly checks for negative or false-zero spawn slots every tick.
// This is the fast-path check that complements the periodic full reconciliation.
func (c *Coordinator) checkSpawnSlotAnomaly(ctx context.Context) error {
	slotsStr, err := c.stateManager.GetField(ctx, "spawnSlots")
	if err != nil {
		return err
	}

	if !isValidNonNegativeInt(slotsStr) {
		c.logger.Warn("spawn slots invalid or negative, triggering reconciliation",
			"value", slotsStr,
		)
		return c.reconcileSpawnSlots(ctx)
	}

	slots := parseIntDefault(slotsStr, 0)
	if slots == 0 {
		// Check for false zero: slots=0 but active < limit
		constitution := c.config.GetConstitution()
		activeJobs, err := c.client.CountActiveJobs(ctx, c.namespace)
		if err != nil {
			return err
		}
		if activeJobs < constitution.CircuitBreakerLimit {
			c.logger.Warn("false zero spawn slots detected, triggering reconciliation",
				"activeJobs", activeJobs,
				"limit", constitution.CircuitBreakerLimit,
			)
			return c.reconcileSpawnSlots(ctx)
		}
	}

	return nil
}

// cleanupStaleAssignments removes assignments for agents whose Jobs have
// completed or no longer exist. Matches the bash coordinator's
// cleanup_stale_assignments().
func (c *Coordinator) cleanupStaleAssignments(ctx context.Context) error {
	state, err := c.stateManager.Load(ctx)
	if err != nil {
		return err
	}

	if len(state.ActiveAssignments) == 0 {
		return nil
	}

	cleaned := make(map[string]int)
	staleCount := 0

	for agent, issue := range state.ActiveAssignments {
		active, err := c.isJobActive(ctx, agent)
		if err != nil {
			// On error, keep the assignment to be safe
			c.logger.Warn("error checking job status, keeping assignment",
				"agent", agent, "issue", issue, "error", err,
			)
			cleaned[agent] = issue
			continue
		}

		if active {
			cleaned[agent] = issue
		} else {
			staleCount++
			c.logger.Info("releasing stale assignment",
				"agent", agent, "issue", issue,
			)
		}
	}

	if staleCount > 0 {
		if err := c.stateManager.UpdateField(ctx, "activeAssignments", formatAssignments(cleaned)); err != nil {
			return fmt.Errorf("updating cleaned assignments: %w", err)
		}
		c.logger.Info("cleaned stale assignments", "count", staleCount)
	}

	return nil
}

// cleanupActiveAgents removes agents from the activeAgents list whose Jobs
// have completed or no longer exist.
func (c *Coordinator) cleanupActiveAgents(ctx context.Context) error {
	agentsStr, err := c.stateManager.GetField(ctx, "activeAgents")
	if err != nil {
		return err
	}
	if agentsStr == "" {
		return nil
	}

	entries := splitAndTrim(agentsStr, ",")
	var kept []string
	removedCount := 0

	for _, entry := range entries {
		parts := splitAndTrim(entry, ":")
		if len(parts) == 0 {
			continue
		}
		agentName := parts[0]

		active, err := c.isJobActive(ctx, agentName)
		if err != nil {
			// On error, keep the entry to be safe
			kept = append(kept, entry)
			continue
		}
		if active {
			kept = append(kept, entry)
		} else {
			removedCount++
		}
	}

	if removedCount > 0 {
		if err := c.stateManager.UpdateField(ctx, "activeAgents", strings.Join(kept, ",")); err != nil {
			return err
		}
		c.logger.Info("cleaned stale agents", "removed", removedCount)
	}

	return nil
}

// tallyGovernanceVotes reads Thought CRs of type "proposal" and "vote",
// tallies votes, and enacts decisions that meet the threshold. This is a
// placeholder for the full governance implementation.
func (c *Coordinator) tallyGovernanceVotes(ctx context.Context) error {
	c.logger.Debug("governance vote tally check")
	// TODO: Full governance implementation — list Thought CRs with
	// label agentex/type=proposal and agentex/type=vote, tally per topic,
	// and enact when threshold is met.
	return nil
}

// isJobActive checks if a Job exists and is still running (not completed).
func (c *Coordinator) isJobActive(ctx context.Context, jobName string) (bool, error) {
	job, err := c.client.GetJob(ctx, c.namespace, jobName)
	if err != nil {
		if k8sclient.IsNotFound(err) {
			return false, nil
		}
		return false, err
	}
	return isJobRunning(job), nil
}

// isJobRunning returns true if the job has no completionTime and active > 0.
func isJobRunning(job *batchv1.Job) bool {
	return job.Status.CompletionTime == nil && job.Status.Active > 0
}

// isValidNonNegativeInt checks if a string is a valid non-negative integer.
func isValidNonNegativeInt(s string) bool {
	if s == "" {
		return false
	}
	n := parseIntDefault(s, -1)
	return n >= 0
}

// splitAndTrim splits a string by sep and trims whitespace from each part,
// excluding empty entries.
func splitAndTrim(s, sep string) []string {
	if s == "" {
		return nil
	}
	var result []string
	for _, part := range strings.Split(s, sep) {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}

// ActiveJobsFromList counts active jobs from a pre-fetched job list.
// Useful when jobs have already been listed for other purposes.
func ActiveJobsFromList(jobs *batchv1.JobList) int {
	count := 0
	for i := range jobs.Items {
		if isJobRunning(&jobs.Items[i]) {
			count++
		}
	}
	return count
}

// ListActiveJobNames returns the names of all currently active jobs.
func (c *Coordinator) ListActiveJobNames(ctx context.Context) ([]string, error) {
	jobs, err := c.client.ListJobs(ctx, c.namespace, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}

	var names []string
	for i := range jobs.Items {
		if isJobRunning(&jobs.Items[i]) {
			names = append(names, jobs.Items[i].Name)
		}
	}
	return names, nil
}
