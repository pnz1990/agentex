package server

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pnz1990/agentex/internal/metrics"
)

func TestServer_HealthEndpoint(t *testing.T) {
	s := New(Config{
		Addr: ":0",
		HealthFn: func() (string, string) {
			return "ok", "all systems operational"
		},
		Logger: slog.Default(),
	})

	// Test via httptest instead of actual server
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	resp := rec.Result()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}

	var hs HealthStatus
	body, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(body, &hs); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if hs.Status != "ok" {
		t.Errorf("status = %q, want ok", hs.Status)
	}
	if hs.Message != "all systems operational" {
		t.Errorf("message = %q, want 'all systems operational'", hs.Message)
	}
	if hs.Uptime == "" {
		t.Error("uptime is empty")
	}
}

func TestServer_HealthEndpoint_Unhealthy(t *testing.T) {
	s := New(Config{
		Addr: ":0",
		HealthFn: func() (string, string) {
			return "error", "coordinator heartbeat stale"
		},
		Logger: slog.Default(),
	})

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	resp := rec.Result()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", resp.StatusCode)
	}

	var hs HealthStatus
	body, _ := io.ReadAll(resp.Body)
	json.Unmarshal(body, &hs)

	if hs.Status != "error" {
		t.Errorf("status = %q, want error", hs.Status)
	}
}

func TestServer_ReadyEndpoint(t *testing.T) {
	readyCalled := false
	s := New(Config{
		Addr: ":0",
		HealthFn: func() (string, string) {
			return "ok", ""
		},
		ReadyFn: func() (string, string) {
			readyCalled = true
			return "ok", "ready to serve"
		},
		Logger: slog.Default(),
	})

	mux := http.NewServeMux()
	mux.HandleFunc("/readyz", s.handleReady)

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if !readyCalled {
		t.Error("ready function was not called")
	}

	resp := rec.Result()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
}

func TestServer_MetricsEndpoint(t *testing.T) {
	reg := metrics.NewRegistry()
	c := reg.NewCounter("test_counter", "Test")
	c.Inc()

	s := New(Config{
		Addr:     ":0",
		Registry: reg,
		Logger:   slog.Default(),
	})

	mux := http.NewServeMux()
	mux.Handle("/metrics", reg.Handler())

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	resp := rec.Result()
	body, _ := io.ReadAll(resp.Body)
	content := string(body)

	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	if !strings.Contains(content, "test_counter 1") {
		t.Errorf("missing counter in output:\n%s", content)
	}

	_ = s // Use s to avoid unused var
}

func TestServer_StartStop(t *testing.T) {
	reg := metrics.NewRegistry()
	s := New(Config{
		Addr:     ":18923", // Use a high port unlikely to be in use
		Registry: reg,
		Logger:   slog.Default(),
	})

	if err := s.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	// Give server time to start
	time.Sleep(50 * time.Millisecond)

	// Verify it's running
	resp, err := http.Get("http://localhost:18923/healthz")
	if err != nil {
		t.Fatalf("get /healthz: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("healthz status = %d, want 200", resp.StatusCode)
	}

	// Stop
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.Stop(ctx); err != nil {
		t.Errorf("stop: %v", err)
	}
}

func TestServer_DefaultHealthFunc(t *testing.T) {
	s := New(Config{
		Addr:   ":0",
		Logger: slog.Default(),
	})

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	resp := rec.Result()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("default health status = %d, want 200", resp.StatusCode)
	}
}

func TestServer_FormatAddr(t *testing.T) {
	s := New(Config{Addr: ":8080"})
	if got := s.FormatAddr(); got != "http://localhost:8080" {
		t.Errorf("FormatAddr() = %q, want http://localhost:8080", got)
	}
}
