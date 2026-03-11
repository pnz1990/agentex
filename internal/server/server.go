// Package server provides the HTTP server for coordinator health,
// readiness, and metrics endpoints. It runs alongside the coordinator
// reconciliation loop, exposing operational data to Kubernetes probes
// and Prometheus scrapers.
package server

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/pnz1990/agentex/internal/metrics"
)

// HealthStatus represents the current health state.
type HealthStatus struct {
	Status    string    `json:"status"`
	Message   string    `json:"message,omitempty"`
	Uptime    string    `json:"uptime"`
	CheckedAt time.Time `json:"checkedAt"`
}

// HealthFunc is called to determine the current health.
// Returns status ("ok", "degraded", "error") and a message.
type HealthFunc func() (status string, message string)

// Server is the HTTP server for health, readiness, and metrics.
type Server struct {
	addr      string
	registry  *metrics.Registry
	healthFn  HealthFunc
	readyFn   HealthFunc
	startTime time.Time
	logger    *slog.Logger

	mu     sync.RWMutex
	server *http.Server
}

// Config holds server configuration.
type Config struct {
	Addr     string            // Listen address (e.g., ":8080")
	Registry *metrics.Registry // Metrics registry
	HealthFn HealthFunc        // Health check function
	ReadyFn  HealthFunc        // Readiness check function
	Logger   *slog.Logger
}

// New creates a new HTTP server.
func New(cfg Config) *Server {
	if cfg.Addr == "" {
		cfg.Addr = ":8080"
	}
	if cfg.HealthFn == nil {
		cfg.HealthFn = func() (string, string) { return "ok", "" }
	}
	if cfg.ReadyFn == nil {
		cfg.ReadyFn = cfg.HealthFn
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	return &Server{
		addr:      cfg.Addr,
		registry:  cfg.Registry,
		healthFn:  cfg.HealthFn,
		readyFn:   cfg.ReadyFn,
		startTime: time.Now(),
		logger:    cfg.Logger,
	}
}

// Start starts the HTTP server in a goroutine.
func (s *Server) Start() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/readyz", s.handleReady)
	if s.registry != nil {
		mux.Handle("/metrics", s.registry.Handler())
	}

	s.mu.Lock()
	s.server = &http.Server{
		Addr:         s.addr,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}
	s.mu.Unlock()

	go func() {
		s.logger.Info("http server starting", "addr", s.addr)
		if err := s.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			s.logger.Error("http server error", "error", err)
		}
	}()

	return nil
}

// Stop gracefully shuts down the HTTP server.
func (s *Server) Stop(ctx context.Context) error {
	s.mu.RLock()
	srv := s.server
	s.mu.RUnlock()

	if srv == nil {
		return nil
	}
	return srv.Shutdown(ctx)
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	status, msg := s.healthFn()

	hs := HealthStatus{
		Status:    status,
		Message:   msg,
		Uptime:    time.Since(s.startTime).Round(time.Second).String(),
		CheckedAt: time.Now().UTC(),
	}

	code := http.StatusOK
	if status != "ok" {
		code = http.StatusServiceUnavailable
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(hs)
}

func (s *Server) handleReady(w http.ResponseWriter, _ *http.Request) {
	status, msg := s.readyFn()

	hs := HealthStatus{
		Status:    status,
		Message:   msg,
		Uptime:    time.Since(s.startTime).Round(time.Second).String(),
		CheckedAt: time.Now().UTC(),
	}

	code := http.StatusOK
	if status != "ok" {
		code = http.StatusServiceUnavailable
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(hs)
}

// Addr returns the configured listen address.
func (s *Server) Addr() string {
	return s.addr
}

// FormatAddr returns the full URL prefix for this server.
func (s *Server) FormatAddr() string {
	return fmt.Sprintf("http://localhost%s", s.addr)
}
