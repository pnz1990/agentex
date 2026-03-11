// Package main is the entry point for the agentex Go coordinator binary.
// It replaces the bash coordinator.sh with a compiled, strongly-typed coordinator
// that manages civilization state through Kubernetes ConfigMaps and kro CRDs.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/pnz1990/agentex/internal/audit"
	"github.com/pnz1990/agentex/internal/config"
	"github.com/pnz1990/agentex/internal/coordinator"
	"github.com/pnz1990/agentex/internal/health"
	"github.com/pnz1990/agentex/internal/k8s"
	"github.com/pnz1990/agentex/internal/metrics"
	"github.com/pnz1990/agentex/internal/server"
)

func main() {
	// Parse command-line flags
	namespace := flag.String("namespace", "agentex", "Kubernetes namespace for agentex resources")
	heartbeatInterval := flag.Duration("heartbeat-interval", 30*time.Second, "Heartbeat interval for coordinator state updates")
	kubeconfig := flag.String("kubeconfig", "", "Path to kubeconfig file (empty for in-cluster)")
	logLevel := flag.String("log-level", "info", "Log level: debug, info, warn, error")
	httpAddr := flag.String("http-addr", ":8080", "HTTP server listen address for health/metrics")
	healthInterval := flag.Duration("health-interval", 60*time.Second, "Interval between health check runs")
	flag.Parse()

	// Configure structured logging
	level := parseLogLevel(*logLevel)
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: level,
	}))
	slog.SetDefault(logger)

	logger.Info("agentex coordinator starting",
		"namespace", *namespace,
		"heartbeatInterval", heartbeatInterval.String(),
		"httpAddr", *httpAddr,
		"version", "go-v0.3.0",
	)

	// Create Kubernetes client
	client, err := k8s.NewClient(*kubeconfig, logger)
	if err != nil {
		logger.Error("failed to create kubernetes client", "error", err)
		os.Exit(1)
	}

	// Create configuration
	cfg := config.NewConfig(*namespace, *heartbeatInterval, *kubeconfig, logger)

	// Create metrics registry and register coordinator metrics (#2058)
	reg := metrics.NewRegistry()
	coordMetrics := coordinator.RegisterMetrics(reg)

	// Create health monitor (#2059)
	healthMon := health.NewMonitor(client, *namespace, *healthInterval, logger)

	// Create audit logger (#2062) — reads bucket/region from constitution at startup
	// (constitution is loaded by coordinator.Run, so we read the env var directly here)
	auditCfg := audit.Config{
		AgentName:  "coordinator",
		Role:       "coordinator",
		Bucket:     os.Getenv("S3_BUCKET"),  // set from constitution in prod
		AwsRegion:  os.Getenv("AWS_REGION"), // set from constitution in prod
		FlushEvery: 60 * time.Second,
	}
	auditLogger := audit.New(auditCfg, logger)

	// Create coordinator, wiring in metrics and health monitor
	coord := coordinator.NewCoordinator(client, cfg, logger).
		WithMetrics(coordMetrics).
		WithHealthMonitor(healthMon).
		WithAuditLogger(auditLogger)

	// Start HTTP server for health and metrics
	httpSrv := server.New(server.Config{
		Addr:     *httpAddr,
		Registry: reg,
		HealthFn: func() (string, string) {
			if coord.IsRunning() {
				return "ok", "coordinator reconciliation loop active"
			}
			return "error", "coordinator reconciliation loop not running"
		},
		ReadyFn: func() (string, string) {
			if coord.IsRunning() {
				return "ok", "ready"
			}
			return "error", "not ready"
		},
		Logger: logger,
	})
	if err := httpSrv.Start(); err != nil {
		logger.Error("failed to start http server", "error", err)
		os.Exit(1)
	}

	// Set up signal handling for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		sig := <-sigCh
		logger.Info("received shutdown signal", "signal", sig.String())
		coord.Stop()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		httpSrv.Stop(shutdownCtx)
		cancel()
	}()

	// Run the coordinator (blocks until shutdown)
	if err := coord.Run(ctx); err != nil {
		if err == context.Canceled {
			logger.Info("coordinator shut down gracefully")
		} else {
			logger.Error("coordinator exited with error", "error", err)
			os.Exit(1)
		}
	}

	logger.Info("coordinator exited")
}

// parseLogLevel converts a string log level to slog.Level.
func parseLogLevel(level string) slog.Level {
	switch level {
	case "debug":
		return slog.LevelDebug
	case "info":
		return slog.LevelInfo
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		fmt.Fprintf(os.Stderr, "unknown log level %q, defaulting to info\n", level)
		return slog.LevelInfo
	}
}
