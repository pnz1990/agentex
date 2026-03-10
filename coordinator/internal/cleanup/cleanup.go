// Package cleanup implements background goroutines for coordinator maintenance tasks.
//
// Replaces the inline cleanup loops in coordinator.sh with properly managed goroutines:
//   - Stale assignment reclaim (every 30s)
//   - Inactive agent pruning (every 60s)
//   - Constitution config refresh (every 60s)
//   - GitHub task queue refresh (every ~2.5min)
package cleanup

import (
	"context"
	"time"

	"go.uber.org/zap"

	"github.com/pnz1990/agentex/coordinator/internal/config"
	"github.com/pnz1990/agentex/coordinator/internal/store"
)

// Runner manages all background cleanup goroutines.
type Runner struct {
	store  *store.Store
	config *config.Config
	log    *zap.Logger
}

// New creates a new cleanup Runner.
func New(s *store.Store, cfg *config.Config, log *zap.Logger) *Runner {
	return &Runner{store: s, config: cfg, log: log}
}

// Start launches all background goroutines. It blocks until ctx is cancelled.
func (r *Runner) Start(ctx context.Context) {
	r.log.Info("cleanup runner starting")

	go r.runStaleAssignmentCleaner(ctx)
	go r.runConfigRefresher(ctx)

	<-ctx.Done()
	r.log.Info("cleanup runner stopping")
}

// runStaleAssignmentCleaner periodically reclaims stale task assignments.
// Replaces the stale assignment cleanup loop in coordinator.sh.
//
// A task is stale if it has been claimed but not completed within StaleAssignTimeout.
// Stale tasks are reset to pending so they can be picked up by another agent.
func (r *Runner) runStaleAssignmentCleaner(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.cleanStaleAssignments()
		}
	}
}

func (r *Runner) cleanStaleAssignments() {
	cfg := r.config.Snapshot()
	staleTasks, err := r.store.GetStaleAssignments(cfg.StaleAssignTimeout)
	if err != nil {
		r.log.Error("get stale assignments", zap.Error(err))
		return
	}

	for _, task := range staleTasks {
		r.log.Info("reclaiming stale assignment",
			zap.Int("issue", task.IssueNumber),
			zap.String("agent", task.AgentName),
			zap.Timep("claimed_at", task.ClaimedAt),
		)
		if err := r.store.ReclaimStaleTask(task.ID); err != nil {
			r.log.Error("reclaim stale task", zap.Error(err), zap.Int64("id", task.ID))
		}
	}
}

// runConfigRefresher periodically reloads configuration from Kubernetes ConfigMaps.
// This ensures the coordinator picks up changes to circuitBreakerLimit, kill switch, etc.
func (r *Runner) runConfigRefresher(ctx context.Context) {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := r.config.Refresh(ctx); err != nil {
				r.log.Error("refresh config", zap.Error(err))
			} else {
				cfg := r.config.Snapshot()
				r.log.Debug("config refreshed",
					zap.Int("circuit_breaker_limit", cfg.CircuitBreakerLimit),
					zap.Bool("kill_switch", cfg.KillSwitchEnabled),
				)
			}
		}
	}
}
