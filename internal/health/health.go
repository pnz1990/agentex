// Package health provides health monitoring for the agentex platform.
// It runs periodic health checks against the Kubernetes cluster and
// produces a structured health report with overall status.
package health

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/pnz1990/agentex/internal/k8s"
)

// Status represents the health status of a check or the overall system.
type Status string

const (
	// StatusHealthy means the check passed without issues.
	StatusHealthy Status = "healthy"
	// StatusDegraded means the check detected a non-critical issue.
	StatusDegraded Status = "degraded"
	// StatusCritical means the check detected a critical issue.
	StatusCritical Status = "critical"
)

// Check is the result of a single health check.
type Check struct {
	Name      string
	Status    Status
	Message   string
	CheckedAt time.Time
}

// Report is the full health report combining all check results.
type Report struct {
	Overall   Status
	Checks    []Check
	CheckedAt time.Time
}

// HealthChecker is the interface for individual health checks.
type HealthChecker interface {
	Name() string
	Check(ctx context.Context) Check
}

// Monitor runs periodic health checks against the cluster.
type Monitor struct {
	client    *k8s.Client
	namespace string
	interval  time.Duration
	checks    []HealthChecker
	logger    *slog.Logger
}

// NewMonitor creates a new health monitor with the given checks.
func NewMonitor(client *k8s.Client, namespace string, interval time.Duration, logger *slog.Logger) *Monitor {
	m := &Monitor{
		client:    client,
		namespace: namespace,
		interval:  interval,
		logger:    logger,
	}

	// Register built-in checks
	m.checks = []HealthChecker{
		NewCoordinatorHeartbeatCheck(client, namespace),
		NewSpawnSlotConsistencyCheck(client, namespace),
		NewConfigMapAccumulationCheck(client, namespace, 200),
		NewKillSwitchCheck(client, namespace),
		NewStaleAssignmentCheck(client, namespace, 30*time.Minute),
	}

	return m
}

// AddCheck adds a custom health check to the monitor.
func (m *Monitor) AddCheck(check HealthChecker) {
	m.checks = append(m.checks, check)
}

// RunOnce executes all health checks and returns a report.
func (m *Monitor) RunOnce(ctx context.Context) Report {
	now := time.Now().UTC()
	report := Report{
		Overall:   StatusHealthy,
		CheckedAt: now,
	}

	for _, checker := range m.checks {
		result := checker.Check(ctx)
		report.Checks = append(report.Checks, result)
	}

	report.Overall = worstStatus(report.Checks)
	return report
}

// Run starts the periodic health check loop. It blocks until ctx is cancelled.
func (m *Monitor) Run(ctx context.Context) {
	m.logger.Info("health monitor starting", "interval", m.interval, "checks", len(m.checks))

	ticker := time.NewTicker(m.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			m.logger.Info("health monitor stopping")
			return
		case <-ticker.C:
			report := m.RunOnce(ctx)
			m.logger.Info("health check completed",
				"overall", report.Overall,
				"checks", len(report.Checks),
			)
			for _, check := range report.Checks {
				if check.Status != StatusHealthy {
					m.logger.Warn("unhealthy check",
						"check", check.Name,
						"status", check.Status,
						"message", check.Message,
					)
				}
			}
		}
	}
}

// worstStatus returns the most severe status across all checks.
func worstStatus(checks []Check) Status {
	worst := StatusHealthy
	for _, check := range checks {
		if statusSeverity(check.Status) > statusSeverity(worst) {
			worst = check.Status
		}
	}
	return worst
}

func statusSeverity(s Status) int {
	switch s {
	case StatusCritical:
		return 2
	case StatusDegraded:
		return 1
	default:
		return 0
	}
}

// --- Built-in Health Checks ---

// coordinatorStateConfigMap is the name of the coordinator state ConfigMap.
const coordinatorStateConfigMap = "coordinator-state"

// killSwitchConfigMap is the name of the kill switch ConfigMap.
const killSwitchConfigMap = "agentex-killswitch"

// CoordinatorHeartbeatCheck verifies that the coordinator heartbeat is recent.
type CoordinatorHeartbeatCheck struct {
	client    *k8s.Client
	namespace string
	maxAge    time.Duration
}

// NewCoordinatorHeartbeatCheck creates a heartbeat check with a 2 minute threshold.
func NewCoordinatorHeartbeatCheck(client *k8s.Client, namespace string) *CoordinatorHeartbeatCheck {
	return &CoordinatorHeartbeatCheck{
		client:    client,
		namespace: namespace,
		maxAge:    2 * time.Minute,
	}
}

func (c *CoordinatorHeartbeatCheck) Name() string { return "coordinator-heartbeat" }

func (c *CoordinatorHeartbeatCheck) Check(ctx context.Context) Check {
	now := time.Now().UTC()

	cm, err := c.client.GetConfigMap(ctx, c.namespace, coordinatorStateConfigMap)
	if err != nil {
		return Check{
			Name:      c.Name(),
			Status:    StatusCritical,
			Message:   fmt.Sprintf("failed to read coordinator state: %v", err),
			CheckedAt: now,
		}
	}

	heartbeat := cm.Data["lastHeartbeat"]
	if heartbeat == "" {
		return Check{
			Name:      c.Name(),
			Status:    StatusCritical,
			Message:   "no heartbeat timestamp found",
			CheckedAt: now,
		}
	}

	ts, err := time.Parse(time.RFC3339, heartbeat)
	if err != nil {
		return Check{
			Name:      c.Name(),
			Status:    StatusCritical,
			Message:   fmt.Sprintf("invalid heartbeat timestamp: %s", heartbeat),
			CheckedAt: now,
		}
	}

	age := now.Sub(ts)
	if age > c.maxAge {
		return Check{
			Name:      c.Name(),
			Status:    StatusCritical,
			Message:   fmt.Sprintf("heartbeat is %.0fs old (threshold: %.0fs)", age.Seconds(), c.maxAge.Seconds()),
			CheckedAt: now,
		}
	}

	return Check{
		Name:      c.Name(),
		Status:    StatusHealthy,
		Message:   fmt.Sprintf("heartbeat %.0fs ago", age.Seconds()),
		CheckedAt: now,
	}
}

// SpawnSlotConsistencyCheck verifies spawn slots are non-negative and
// consistent with the number of active jobs.
type SpawnSlotConsistencyCheck struct {
	client    *k8s.Client
	namespace string
}

// NewSpawnSlotConsistencyCheck creates a spawn slot consistency check.
func NewSpawnSlotConsistencyCheck(client *k8s.Client, namespace string) *SpawnSlotConsistencyCheck {
	return &SpawnSlotConsistencyCheck{
		client:    client,
		namespace: namespace,
	}
}

func (c *SpawnSlotConsistencyCheck) Name() string { return "spawn-slot-consistency" }

func (c *SpawnSlotConsistencyCheck) Check(ctx context.Context) Check {
	now := time.Now().UTC()

	cm, err := c.client.GetConfigMap(ctx, c.namespace, coordinatorStateConfigMap)
	if err != nil {
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("failed to read coordinator state: %v", err),
			CheckedAt: now,
		}
	}

	slotsStr := cm.Data["spawnSlots"]
	slots, err := strconv.Atoi(slotsStr)
	if err != nil {
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("invalid spawnSlots value: %q", slotsStr),
			CheckedAt: now,
		}
	}

	if slots < 0 {
		return Check{
			Name:      c.Name(),
			Status:    StatusCritical,
			Message:   fmt.Sprintf("negative spawn slots: %d", slots),
			CheckedAt: now,
		}
	}

	// Check consistency with active jobs
	activeJobs, err := c.client.CountActiveJobs(ctx, c.namespace)
	if err != nil {
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("could not count active jobs: %v", err),
			CheckedAt: now,
		}
	}

	// If slots + activeJobs is unreasonably high, flag it as degraded.
	// We can't check the exact limit without the constitution, so we just
	// verify basic sanity: slots should not exceed a reasonable max and
	// the sum should be positive.
	if slots+activeJobs > 50 {
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("slots=%d + activeJobs=%d = %d (suspiciously high)", slots, activeJobs, slots+activeJobs),
			CheckedAt: now,
		}
	}

	return Check{
		Name:      c.Name(),
		Status:    StatusHealthy,
		Message:   fmt.Sprintf("slots=%d, activeJobs=%d", slots, activeJobs),
		CheckedAt: now,
	}
}

// ConfigMapAccumulationCheck checks whether there are too many ConfigMaps
// in the namespace, which indicates a resource leak.
type ConfigMapAccumulationCheck struct {
	client    *k8s.Client
	namespace string
	threshold int
}

// NewConfigMapAccumulationCheck creates a ConfigMap accumulation check.
func NewConfigMapAccumulationCheck(client *k8s.Client, namespace string, threshold int) *ConfigMapAccumulationCheck {
	return &ConfigMapAccumulationCheck{
		client:    client,
		namespace: namespace,
		threshold: threshold,
	}
}

func (c *ConfigMapAccumulationCheck) Name() string { return "configmap-accumulation" }

func (c *ConfigMapAccumulationCheck) Check(ctx context.Context) Check {
	now := time.Now().UTC()

	cms, err := c.client.ListConfigMaps(ctx, c.namespace, metav1.ListOptions{})
	if err != nil {
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("failed to list configmaps: %v", err),
			CheckedAt: now,
		}
	}

	count := len(cms.Items)
	if count > c.threshold {
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("%d configmaps in namespace (threshold: %d)", count, c.threshold),
			CheckedAt: now,
		}
	}

	return Check{
		Name:      c.Name(),
		Status:    StatusHealthy,
		Message:   fmt.Sprintf("%d configmaps (threshold: %d)", count, c.threshold),
		CheckedAt: now,
	}
}

// KillSwitchCheck verifies the kill switch ConfigMap state.
type KillSwitchCheck struct {
	client    *k8s.Client
	namespace string
}

// NewKillSwitchCheck creates a kill switch check.
func NewKillSwitchCheck(client *k8s.Client, namespace string) *KillSwitchCheck {
	return &KillSwitchCheck{
		client:    client,
		namespace: namespace,
	}
}

func (c *KillSwitchCheck) Name() string { return "kill-switch" }

func (c *KillSwitchCheck) Check(ctx context.Context) Check {
	now := time.Now().UTC()

	cm, err := c.client.GetConfigMap(ctx, c.namespace, killSwitchConfigMap)
	if err != nil {
		if k8s.IsNotFound(err) {
			// No kill switch ConfigMap is normal — it means the switch is inactive.
			return Check{
				Name:      c.Name(),
				Status:    StatusHealthy,
				Message:   "kill switch ConfigMap not present (inactive)",
				CheckedAt: now,
			}
		}
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("failed to read kill switch: %v", err),
			CheckedAt: now,
		}
	}

	enabled := cm.Data["enabled"]
	reason := cm.Data["reason"]

	if enabled == "true" {
		return Check{
			Name:      c.Name(),
			Status:    StatusCritical,
			Message:   fmt.Sprintf("kill switch is ACTIVE: %s", reason),
			CheckedAt: now,
		}
	}

	return Check{
		Name:      c.Name(),
		Status:    StatusHealthy,
		Message:   "kill switch is inactive",
		CheckedAt: now,
	}
}

// StaleAssignmentCheck looks for assignments that have been active longer
// than the threshold without a running job, indicating a potential leak.
type StaleAssignmentCheck struct {
	client    *k8s.Client
	namespace string
	maxAge    time.Duration
}

// NewStaleAssignmentCheck creates a stale assignment check.
func NewStaleAssignmentCheck(client *k8s.Client, namespace string, maxAge time.Duration) *StaleAssignmentCheck {
	return &StaleAssignmentCheck{
		client:    client,
		namespace: namespace,
		maxAge:    maxAge,
	}
}

func (c *StaleAssignmentCheck) Name() string { return "stale-assignments" }

func (c *StaleAssignmentCheck) Check(ctx context.Context) Check {
	now := time.Now().UTC()

	cm, err := c.client.GetConfigMap(ctx, c.namespace, coordinatorStateConfigMap)
	if err != nil {
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("failed to read coordinator state: %v", err),
			CheckedAt: now,
		}
	}

	assignmentsStr := cm.Data["activeAssignments"]
	if assignmentsStr == "" {
		return Check{
			Name:      c.Name(),
			Status:    StatusHealthy,
			Message:   "no active assignments",
			CheckedAt: now,
		}
	}

	// Parse assignments and check for each agent whether a running Job exists
	staleCount := 0
	totalCount := 0

	for _, pair := range splitCommaPairs(assignmentsStr) {
		if pair.agent == "" {
			continue
		}
		totalCount++

		job, err := c.client.GetJob(ctx, c.namespace, pair.agent)
		if err != nil {
			if k8s.IsNotFound(err) {
				staleCount++
			}
			continue
		}

		// If the job has completed, count as stale
		if job.Status.CompletionTime != nil {
			staleCount++
			continue
		}

		// If the job has no active pods and was created more than maxAge ago, it's stale
		if job.Status.Active == 0 && now.Sub(job.CreationTimestamp.Time) > c.maxAge {
			staleCount++
		}
	}

	if staleCount > 0 {
		return Check{
			Name:      c.Name(),
			Status:    StatusDegraded,
			Message:   fmt.Sprintf("%d of %d assignments are stale (threshold: %s)", staleCount, totalCount, c.maxAge),
			CheckedAt: now,
		}
	}

	return Check{
		Name:      c.Name(),
		Status:    StatusHealthy,
		Message:   fmt.Sprintf("%d active assignments, none stale", totalCount),
		CheckedAt: now,
	}
}

// agentIssuePair is a parsed agent:issue assignment entry.
type agentIssuePair struct {
	agent string
	issue string
}

// splitCommaPairs parses "agent1:123,agent2:456" into pairs.
func splitCommaPairs(s string) []agentIssuePair {
	if s == "" {
		return nil
	}
	var result []agentIssuePair
	for _, chunk := range splitByComma(s) {
		idx := -1
		for i, ch := range chunk {
			if ch == ':' {
				idx = i
				break
			}
		}
		if idx < 0 {
			continue
		}
		result = append(result, agentIssuePair{
			agent: chunk[:idx],
			issue: chunk[idx+1:],
		})
	}
	return result
}

// splitByComma splits a string by comma, trimming whitespace.
func splitByComma(s string) []string {
	var result []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ',' {
			part := trimSpace(s[start:i])
			if part != "" {
				result = append(result, part)
			}
			start = i + 1
		}
	}
	return result
}

// trimSpace trims leading and trailing whitespace.
func trimSpace(s string) string {
	start := 0
	for start < len(s) && (s[start] == ' ' || s[start] == '\t') {
		start++
	}
	end := len(s)
	for end > start && (s[end-1] == ' ' || s[end-1] == '\t') {
		end--
	}
	return s[start:end]
}
