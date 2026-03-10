// Command coordinator is the agentex coordination service.
//
// It replaces the coordinator.sh bash script with a proper Go binary that:
//   - Persists state in SQLite (survives restarts, no ConfigMap string limits)
//   - Provides a REST API for agents to claim tasks, register votes, etc.
//   - Runs cleanup goroutines with proper goroutine management
//   - Reads circuit breaker / kill switch state from Kubernetes ConfigMaps
//   - Supports liveness and readiness probes for Kubernetes
//
// Usage:
//
//	coordinator [flags]
//
// Flags:
//
//	-db string      Path to SQLite database (default: /data/coordinator.db)
//	-addr string    HTTP listen address (default: :8080)
//	-namespace string  Kubernetes namespace (default: agentex)
//
// Environment variables (override flags):
//
//	DB_PATH         Path to SQLite database
//	LISTEN_ADDR     HTTP listen address
//	NAMESPACE       Kubernetes namespace
//	REPO            GitHub repository (owner/repo)
//	BEDROCK_REGION  AWS region for Bedrock
//	S3_BUCKET       S3 bucket for agent memory
package main

import (
	"context"
	"flag"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.uber.org/zap"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/pnz1990/agentex/coordinator/internal/api"
	"github.com/pnz1990/agentex/coordinator/internal/cleanup"
	"github.com/pnz1990/agentex/coordinator/internal/config"
	"github.com/pnz1990/agentex/coordinator/internal/store"
)

func main() {
	// Flags — all can be overridden by env vars (env takes precedence via config.New)
	dbPath := flag.String("db", "/data/coordinator.db", "SQLite database path")
	addr := flag.String("addr", ":8080", "HTTP listen address")
	namespace := flag.String("namespace", "agentex", "Kubernetes namespace")
	kubeconfig := flag.String("kubeconfig", "", "Path to kubeconfig (leave empty for in-cluster)")
	flag.Parse()

	// Override from env if set
	if v := os.Getenv("DB_PATH"); v != "" {
		*dbPath = v
	}
	if v := os.Getenv("LISTEN_ADDR"); v != "" {
		*addr = v
	}
	if v := os.Getenv("NAMESPACE"); v != "" {
		*namespace = v
	}

	// Set up structured logging
	log, err := zap.NewProduction()
	if err != nil {
		panic("failed to create logger: " + err.Error())
	}
	defer log.Sync()

	log.Info("agentex coordinator starting",
		zap.String("db", *dbPath),
		zap.String("addr", *addr),
		zap.String("namespace", *namespace),
	)

	// Kubernetes client
	k8sClient, err := buildK8sClient(*kubeconfig)
	if err != nil {
		log.Fatal("build k8s client", zap.Error(err))
	}

	// Configuration (reads from constitution ConfigMap)
	cfg := config.New(k8sClient)
	cfg.Namespace = *namespace

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initial config refresh — non-fatal if it fails (we have defaults)
	if err := cfg.Refresh(ctx); err != nil {
		log.Warn("initial config refresh failed, using defaults", zap.Error(err))
	}

	// Open database
	s, err := store.Open(*dbPath)
	if err != nil {
		log.Fatal("open store", zap.Error(err))
	}
	defer s.Close()
	log.Info("database opened", zap.String("path", *dbPath))

	// Start cleanup goroutines
	cleanupRunner := cleanup.New(s, cfg, log)
	go cleanupRunner.Start(ctx)

	// HTTP server
	apiServer := api.New(s, cfg, log)
	httpServer := &http.Server{
		Addr:         *addr,
		Handler:      apiServer,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start serving
	go func() {
		log.Info("HTTP server listening", zap.String("addr", *addr))
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal("http server", zap.Error(err))
		}
	}()

	// Wait for shutdown signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	sig := <-sigCh
	log.Info("shutdown signal received", zap.String("signal", sig.String()))

	// Graceful shutdown
	cancel() // stop cleanup goroutines

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutdownCancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", zap.Error(err))
	}

	log.Info("coordinator stopped")
}

// buildK8sClient creates a Kubernetes client from in-cluster config or kubeconfig file.
func buildK8sClient(kubeconfigPath string) (kubernetes.Interface, error) {
	var restConfig *rest.Config
	var err error

	if kubeconfigPath != "" {
		restConfig, err = clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	} else {
		restConfig, err = rest.InClusterConfig()
		if err != nil {
			// Fallback to default kubeconfig location for local development
			restConfig, err = clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
		}
	}
	if err != nil {
		return nil, err
	}

	return kubernetes.NewForConfig(restConfig)
}
