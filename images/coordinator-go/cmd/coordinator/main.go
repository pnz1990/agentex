// Command coordinator is the agentex coordinator service.
// It replaces the 4,471-line coordinator.sh with a type-safe Go binary.
//
// Phase 1a implements:
//   - HTTP API for agents to claim tasks, spawn successors, and file reports
//   - SQLite persistent state (replaces ConfigMap strings)
//   - Atomic task claiming with proper CAS operations
//   - Vote tallying and governance enactment
//   - Circuit breaker and spawn slot management
//   - Periodic cleanup loops with goroutine management
//   - Health and readiness endpoints
//
// The bash coordinator continues to run alongside during migration.
// Agents opt-in to the Go coordinator by checking COORDINATOR_URL env var.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	"github.com/pnz1990/agentex/coordinator/internal/api"
	"github.com/pnz1990/agentex/coordinator/internal/governance"
	"github.com/pnz1990/agentex/coordinator/internal/spawncontrol"
	"github.com/pnz1990/agentex/coordinator/internal/state"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("coordinator failed", "error", err)
		os.Exit(1)
	}
}

// Config holds coordinator configuration.
type Config struct {
	Namespace          string
	DBPath             string
	Port               int
	CircuitBreakerLimit int
	VoteThreshold      int
	JobTTLSeconds      int
	HeartbeatInterval  time.Duration
	StaleAssignTimeout time.Duration
}

func configFromEnv() *Config {
	cfg := &Config{
		Namespace:           getEnv("NAMESPACE", "agentex"),
		DBPath:              getEnv("DB_PATH", "/data/coordinator.db"),
		Port:                getEnvInt("PORT", 8080),
		CircuitBreakerLimit: getEnvInt("CIRCUIT_BREAKER_LIMIT", 10),
		VoteThreshold:       getEnvInt("VOTE_THRESHOLD", 3),
		JobTTLSeconds:       getEnvInt("JOB_TTL_SECONDS", 3600),
		HeartbeatInterval:   30 * time.Second,
		StaleAssignTimeout:  5 * time.Minute,
	}
	return cfg
}

func run(logger *slog.Logger) error {
	cfg := configFromEnv()

	logger.Info("coordinator starting",
		"namespace", cfg.Namespace,
		"dbPath", cfg.DBPath,
		"port", cfg.Port,
		"circuitBreakerLimit", cfg.CircuitBreakerLimit,
		"voteThreshold", cfg.VoteThreshold,
	)

	// Initialize persistent state
	db, err := state.New(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("init state db: %w", err)
	}
	defer db.Close()
	logger.Info("state database initialized", "path", cfg.DBPath)

	// Initialize circuit breaker limit
	if err := db.SetCircuitBreakerLimit(cfg.CircuitBreakerLimit); err != nil {
		return fmt.Errorf("set circuit breaker limit: %w", err)
	}

	// Initialize Kubernetes client
	k8sConfig, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("get k8s config: %w", err)
	}
	k8sClient, err := kubernetes.NewForConfig(k8sConfig)
	if err != nil {
		return fmt.Errorf("create k8s client: %w", err)
	}
	logger.Info("kubernetes client initialized")

	// Initialize subsystems
	govEngine := governance.New(db, k8sClient, cfg.Namespace, cfg.VoteThreshold, logger)
	spawnCtrl := spawncontrol.New(db, k8sClient, cfg.Namespace, logger)

	// Start HTTP API server
	mux := http.NewServeMux()
	handler := api.New(db, logger)
	handler.RegisterRoutes(mux)

	// Add request logging middleware
	loggedMux := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		mux.ServeHTTP(w, r)
		logger.Debug("http request", "method", r.Method, "path", r.URL.Path, "duration", time.Since(start))
	})

	srv := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.Port),
		Handler:      loggedMux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start background goroutines
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go runHeartbeatLoop(ctx, cfg, db, k8sClient, govEngine, spawnCtrl, logger)
	go runGovLoop(ctx, cfg, govEngine, logger)
	go runCleanupLoop(ctx, cfg, db, spawnCtrl, logger)
	go runSpawnReconcileLoop(ctx, cfg, db, spawnCtrl, logger)

	// Handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		<-sigCh
		logger.Info("received shutdown signal")
		cancel()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer shutdownCancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			logger.Error("http server shutdown", "error", err)
		}
	}()

	logger.Info("http server starting", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("http server: %w", err)
	}

	logger.Info("coordinator shutdown complete")
	return nil
}

// runHeartbeatLoop logs coordinator health periodically.
func runHeartbeatLoop(ctx context.Context, cfg *Config, db *state.DB, k8s kubernetes.Interface,
	gov *governance.Engine, spawn *spawncontrol.Controller, logger *slog.Logger) {

	ticker := time.NewTicker(cfg.HeartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Log current state
			tasks, _ := db.GetQueuedTasks(100)
			assignments, _ := db.GetActiveAssignments()
			slots, _ := db.GetAvailableSpawnSlots()
			activeJobs, err := spawn.CountActiveJobs(ctx)
			if err != nil {
				logger.Warn("count active jobs", "error", err)
			}

			logger.Info("coordinator heartbeat",
				"queuedTasks", len(tasks),
				"activeAssignments", len(assignments),
				"spawnSlotsAvail", slots,
				"activeJobs", activeJobs,
			)
		}
	}
}

// runGovLoop runs the governance vote tallying loop every ~90 seconds.
func runGovLoop(ctx context.Context, cfg *Config, gov *governance.Engine, logger *slog.Logger) {
	ticker := time.NewTicker(90 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			enacted, err := gov.TallyAndEnact(ctx)
			if err != nil {
				logger.Warn("governance tally", "error", err)
				continue
			}
			if len(enacted) > 0 {
				logger.Info("governance decisions enacted", "topics", enacted)
			}
		}
	}
}

// runCleanupLoop handles stale assignments and zombie jobs.
func runCleanupLoop(ctx context.Context, cfg *Config, db *state.DB, spawn *spawncontrol.Controller, logger *slog.Logger) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	// Full cleanup every ~30 minutes (60 iterations)
	fullCleanupEvery := 60
	iteration := 0

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			iteration++

			// Every tick: clean stale assignments
			released, err := db.CleanupStaleAssignments(cfg.StaleAssignTimeout)
			if err != nil {
				logger.Warn("cleanup stale assignments", "error", err)
			} else if released > 0 {
				logger.Info("released stale assignments", "count", released)
			}

			// Every ~30 min: clean zombie jobs
			if iteration%fullCleanupEvery == 0 {
				deleted, err := spawn.CleanupZombieJobs(ctx, cfg.JobTTLSeconds)
				if err != nil {
					logger.Warn("cleanup zombie jobs", "error", err)
				} else if deleted > 0 {
					logger.Info("deleted zombie jobs", "count", deleted)
				}
			}
		}
	}
}

// runSpawnReconcileLoop periodically reconciles spawn slots with actual job count.
// This prevents drift when pods crash or coordinator restarts.
func runSpawnReconcileLoop(ctx context.Context, cfg *Config, db *state.DB, spawn *spawncontrol.Controller, logger *slog.Logger) {
	ticker := time.NewTicker(2 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := spawn.ReconcileSpawnSlots(ctx, cfg.CircuitBreakerLimit); err != nil {
				logger.Warn("reconcile spawn slots", "error", err)
			}
		}
	}
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func getEnvInt(key string, defaultVal int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return defaultVal
}
