// Package spawncontrol implements the circuit breaker and spawn slot management
// for safe agent proliferation control.
package spawncontrol

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"

	"github.com/pnz1990/agentex/coordinator/internal/state"
)

// Controller manages spawn slots and circuit breaker logic.
type Controller struct {
	db        *state.DB
	k8s       kubernetes.Interface
	namespace string
	logger    *slog.Logger
}

// New creates a new spawn controller.
func New(db *state.DB, k8s kubernetes.Interface, namespace string, logger *slog.Logger) *Controller {
	return &Controller{
		db:        db,
		k8s:       k8s,
		namespace: namespace,
		logger:    logger,
	}
}

// KillSwitchStatus represents the current kill switch state.
type KillSwitchStatus struct {
	Enabled bool
	Reason  string
}

// CheckKillSwitch reads the agentex-killswitch ConfigMap.
func (c *Controller) CheckKillSwitch(ctx context.Context) (*KillSwitchStatus, error) {
	cm, err := c.k8s.CoreV1().ConfigMaps(c.namespace).Get(ctx, "agentex-killswitch", metav1.GetOptions{})
	if err != nil {
		// If killswitch doesn't exist, treat as disabled
		return &KillSwitchStatus{Enabled: false}, nil
	}
	return &KillSwitchStatus{
		Enabled: cm.Data["enabled"] == "true",
		Reason:  cm.Data["reason"],
	}, nil
}

// CountActiveJobs returns the number of currently running Jobs.
// A Job is "active" when it has at least one active pod and no completion time.
func (c *Controller) CountActiveJobs(ctx context.Context) (int, error) {
	jobs, err := c.k8s.BatchV1().Jobs(c.namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return 0, fmt.Errorf("list jobs: %w", err)
	}

	active := 0
	for _, job := range jobs.Items {
		if job.Status.CompletionTime != nil {
			continue // completed
		}
		if job.Status.Active > 0 {
			active++
		}
	}
	return active, nil
}

// ReconcileSpawnSlots synchronizes spawn slots with actual active job count.
// This prevents drift between the slot counter and reality (e.g., after a coordinator restart).
func (c *Controller) ReconcileSpawnSlots(ctx context.Context, circuitBreakerLimit int) error {
	activeJobs, err := c.CountActiveJobs(ctx)
	if err != nil {
		return fmt.Errorf("count active jobs: %w", err)
	}

	available := circuitBreakerLimit - activeJobs
	if available < 0 {
		available = 0
	}

	if err := c.db.Set("circuitBreakerLimit", fmt.Sprintf("%d", circuitBreakerLimit)); err != nil {
		return err
	}
	if err := c.db.SetCircuitBreakerLimit(available); err != nil {
		return err
	}

	c.logger.Info("spawn slots reconciled", "activeJobs", activeJobs, "limit", circuitBreakerLimit, "available", available)
	return nil
}

// SpawnDecision is the result of a spawn eligibility check.
type SpawnDecision struct {
	Allowed     bool
	Reason      string
	ActiveJobs  int
	SlotLimit   int
}

// EvaluateSpawn checks all spawn control mechanisms and returns a decision.
func (c *Controller) EvaluateSpawn(ctx context.Context, agentName, role string) (*SpawnDecision, error) {
	// 1. Check kill switch
	ks, err := c.CheckKillSwitch(ctx)
	if err != nil {
		return nil, fmt.Errorf("kill switch check: %w", err)
	}
	if ks.Enabled {
		return &SpawnDecision{
			Allowed: false,
			Reason:  "kill switch active: " + ks.Reason,
		}, nil
	}

	// 2. Check planner constraint (planners must not spawn planners)
	if role == "planner" {
		return &SpawnDecision{
			Allowed: false,
			Reason:  "planners must not spawn planner successors — planner-loop Deployment handles perpetuation",
		}, nil
	}

	// 3. Attempt to acquire spawn slot
	granted, err := c.db.RequestSpawnSlot()
	if err != nil {
		return nil, fmt.Errorf("request spawn slot: %w", err)
	}
	if !granted {
		slots, _ := c.db.GetAvailableSpawnSlots()
		activeJobs, _ := c.CountActiveJobs(ctx)
		return &SpawnDecision{
			Allowed:    false,
			Reason:     fmt.Sprintf("circuit breaker: no slots available (active=%d)", activeJobs),
			ActiveJobs: activeJobs,
			SlotLimit:  slots,
		}, nil
	}

	return &SpawnDecision{Allowed: true}, nil
}

// CleanupZombieJobs deletes Jobs that have completed but are accumulating.
func (c *Controller) CleanupZombieJobs(ctx context.Context, ttlSeconds int) (int, error) {
	jobs, err := c.k8s.BatchV1().Jobs(c.namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return 0, err
	}

	cutoff := time.Now().UTC().Add(-time.Duration(ttlSeconds) * time.Second)
	deleted := 0
	for _, job := range jobs.Items {
		if job.Status.CompletionTime == nil {
			continue // still running
		}
		if job.Status.CompletionTime.Time.Before(cutoff) {
			// Delete the job
			propagation := metav1.DeletePropagationBackground
			err := c.k8s.BatchV1().Jobs(c.namespace).Delete(ctx, job.Name, metav1.DeleteOptions{
				PropagationPolicy: &propagation,
			})
			if err != nil {
				c.logger.Warn("failed to delete zombie job", "job", job.Name, "error", err)
				continue
			}
			deleted++
			c.logger.Info("deleted zombie job", "job", job.Name, "completedAt", job.Status.CompletionTime.Time)
		}
	}
	return deleted, nil
}
