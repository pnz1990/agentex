// Package coordinator provides coordinator metrics.
// This file defines the Prometheus-compatible metrics exposed by the coordinator.
package coordinator

import (
	"github.com/pnz1990/agentex/internal/metrics"
)

// Metrics holds all coordinator metrics.
type Metrics struct {
	// Reconciliation loop
	ReconcileTotal    *metrics.Counter // Total reconciliation cycles
	ReconcileErrors   *metrics.Counter // Failed reconciliation cycles
	ReconcileDuration *metrics.Gauge   // Last reconcile duration in seconds

	// Agent lifecycle
	AgentsSpawned   *metrics.Counter // Total agents spawned
	AgentsCompleted *metrics.Counter // Total agents completed
	AgentsFailed    *metrics.Counter // Total agents failed
	AgentsActive    *metrics.Gauge   // Currently active agents

	// Task queue
	TaskQueueSize  *metrics.Gauge   // Number of tasks in queue
	TasksClaimed   *metrics.Counter // Total tasks claimed by agents
	TasksCompleted *metrics.Counter // Total tasks completed

	// Health
	HealthCheckTotal  *metrics.Counter // Total health checks run
	HealthCheckErrors *metrics.Counter // Health checks that found issues
	HealthStatus      *metrics.Gauge   // 1 = healthy, 0 = degraded, -1 = critical

	// Circuit breaker
	CircuitBreakerLimit *metrics.Gauge   // Current circuit breaker limit
	SpawnSlots          *metrics.Gauge   // Available spawn slots
	SpawnBlocked        *metrics.Counter // Times spawn was blocked by circuit breaker

	// Kill switch
	KillSwitchActive *metrics.Gauge // 1 = active, 0 = inactive
}

// RegisterMetrics creates and registers all coordinator metrics with the given registry.
func RegisterMetrics(r *metrics.Registry) *Metrics {
	return &Metrics{
		ReconcileTotal:    r.NewCounter("agentex_coordinator_reconcile_total", "Total reconciliation cycles"),
		ReconcileErrors:   r.NewCounter("agentex_coordinator_reconcile_errors_total", "Failed reconciliation cycles"),
		ReconcileDuration: r.NewGauge("agentex_coordinator_reconcile_duration_seconds", "Last reconcile duration in seconds"),

		AgentsSpawned:   r.NewCounter("agentex_agents_spawned_total", "Total agents spawned"),
		AgentsCompleted: r.NewCounter("agentex_agents_completed_total", "Total agents completed"),
		AgentsFailed:    r.NewCounter("agentex_agents_failed_total", "Total agents failed"),
		AgentsActive:    r.NewGauge("agentex_agents_active", "Currently active agents"),

		TaskQueueSize:  r.NewGauge("agentex_task_queue_size", "Number of tasks in queue"),
		TasksClaimed:   r.NewCounter("agentex_tasks_claimed_total", "Total tasks claimed by agents"),
		TasksCompleted: r.NewCounter("agentex_tasks_completed_total", "Total tasks completed"),

		HealthCheckTotal:  r.NewCounter("agentex_health_checks_total", "Total health checks run"),
		HealthCheckErrors: r.NewCounter("agentex_health_check_errors_total", "Health checks that found issues"),
		HealthStatus:      r.NewGauge("agentex_health_status", "System health: 1=healthy 0=degraded -1=critical"),

		CircuitBreakerLimit: r.NewGauge("agentex_circuit_breaker_limit", "Current circuit breaker limit"),
		SpawnSlots:          r.NewGauge("agentex_spawn_slots_available", "Available spawn slots"),
		SpawnBlocked:        r.NewCounter("agentex_spawn_blocked_total", "Times spawn was blocked by circuit breaker"),

		KillSwitchActive: r.NewGauge("agentex_killswitch_active", "Kill switch state: 1=active 0=inactive"),
	}
}
