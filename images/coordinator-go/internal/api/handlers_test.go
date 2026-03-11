package api_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/pnz1990/agentex/coordinator/internal/api"
	"github.com/pnz1990/agentex/coordinator/internal/db"
)

// newTestHandler creates a Handler backed by a temporary in-memory database.
func newTestHandler(t *testing.T) *api.Handler {
	t.Helper()
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return api.New(d)
}

// TestHealth_OK verifies that /health returns 200 and db=ok.
func TestHealth_OK(t *testing.T) {
	h := newTestHandler(t)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("GET /health = %d, want 200", rec.Code)
	}

	var body map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode health response: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("health.status = %q, want ok", body["status"])
	}
	if body["db"] != "ok" {
		t.Errorf("health.db = %q, want ok", body["db"])
	}
}

// TestAllStubEndpoints_Return501 verifies all stub endpoints return 501.
// This is the contract for the skeleton: endpoints exist but are not yet wired.
var stubRoutes = []struct {
	method string
	path   string
}{
	{http.MethodGet, "/api/tasks"},
	{http.MethodGet, "/api/tasks/42"},
	{http.MethodPost, "/api/tasks/claim"},
	{http.MethodPost, "/api/tasks/release"},
	{http.MethodGet, "/api/agents"},
	{http.MethodGet, "/api/agents/worker-123/activity"},
	{http.MethodGet, "/api/agents/worker-123/stats"},
	{http.MethodGet, "/api/debates"},
	{http.MethodGet, "/api/debates/thread-abc"},
	{http.MethodPost, "/api/debates"},
	{http.MethodGet, "/api/proposals"},
	{http.MethodPost, "/api/proposals"},
	{http.MethodPost, "/api/proposals/1/vote"},
	{http.MethodGet, "/api/metrics"},
	{http.MethodGet, "/api/metrics/snapshot"},
}

func TestAllStubEndpoints_Return501(t *testing.T) {
	h := newTestHandler(t)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	for _, tc := range stubRoutes {
		t.Run(tc.method+"_"+tc.path, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, tc.path, nil)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)

			if rec.Code != http.StatusNotImplemented {
				t.Errorf("%s %s = %d, want 501", tc.method, tc.path, rec.Code)
			}

			// Response must be valid JSON with an "error" key
			var body map[string]any
			if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
				t.Errorf("%s %s: response is not valid JSON: %v", tc.method, tc.path, err)
				return
			}
			if _, ok := body["error"]; !ok {
				t.Errorf("%s %s: response missing 'error' key: %v", tc.method, tc.path, body)
			}
		})
	}
}

// TestHealth_ContentType verifies /health returns application/json.
func TestHealth_ContentType(t *testing.T) {
	h := newTestHandler(t)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	ct := rec.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
}

// TestHealth_HasUptime verifies /health response includes uptime field.
func TestHealth_HasUptime(t *testing.T) {
	h := newTestHandler(t)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	var body map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode health: %v", err)
	}
	if _, ok := body["uptime"]; !ok {
		t.Errorf("/health response missing 'uptime' field: %v", body)
	}
}
