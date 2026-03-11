package api_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/pnz1990/agentex/coordinator/internal/api"
	"github.com/pnz1990/agentex/coordinator/internal/db"
	"github.com/pnz1990/agentex/coordinator/internal/models"
)

func newTestHandler(t *testing.T) *api.Handler {
	t.Helper()
	dir := t.TempDir()
	database, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("db.Open failed: %v", err)
	}
	t.Cleanup(func() { database.Close() })
	return api.New(database)
}

func TestHealthEndpoint(t *testing.T) {
	h := newTestHandler(t)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("GET /health: want 200, got %d", rr.Code)
	}

	var status models.HealthStatus
	if err := json.NewDecoder(rr.Body).Decode(&status); err != nil {
		t.Fatalf("decode /health response: %v", err)
	}
	if status.Status != "ok" {
		t.Errorf("health status: want %q, got %q", "ok", status.Status)
	}
	if !status.DBPing {
		t.Error("health.db_ping: want true, got false")
	}
}

// stubEndpoints lists all endpoints that should return 501 Not Implemented.
var stubEndpoints = []struct {
	method string
	path   string
}{
	{http.MethodGet, "/api/tasks"},
	{http.MethodPost, "/api/tasks"},
	{http.MethodPost, "/api/tasks/claim"},
	{http.MethodGet, "/api/agents"},
	{http.MethodPost, "/api/agents/register"},
	{http.MethodPost, "/api/agents/heartbeat"},
	{http.MethodGet, "/api/proposals"},
	{http.MethodPost, "/api/proposals"},
	{http.MethodPost, "/api/spawn/acquire"},
	{http.MethodPost, "/api/spawn/release"},
	{http.MethodGet, "/api/spawn/slots"},
	{http.MethodGet, "/api/debates"},
	{http.MethodPost, "/api/debates"},
}

func TestStubEndpointsReturn501(t *testing.T) {
	h := newTestHandler(t)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	for _, ep := range stubEndpoints {
		t.Run(ep.method+" "+ep.path, func(t *testing.T) {
			req := httptest.NewRequest(ep.method, ep.path, nil)
			rr := httptest.NewRecorder()
			mux.ServeHTTP(rr, req)

			if rr.Code != http.StatusNotImplemented {
				t.Errorf("%s %s: want 501, got %d", ep.method, ep.path, rr.Code)
			}

			// Response must be valid JSON.
			var resp map[string]any
			if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
				t.Errorf("%s %s: response not valid JSON: %v", ep.method, ep.path, err)
			}
			if resp["error"] != "not implemented" {
				t.Errorf("%s %s: want error='not implemented', got %v", ep.method, ep.path, resp["error"])
			}
		})
	}
}

func TestResponseContentType(t *testing.T) {
	h := newTestHandler(t)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	for _, ep := range append(stubEndpoints, struct{ method, path string }{http.MethodGet, "/health"}) {
		t.Run(ep.method+" "+ep.path, func(t *testing.T) {
			req := httptest.NewRequest(ep.method, ep.path, nil)
			rr := httptest.NewRecorder()
			mux.ServeHTTP(rr, req)

			ct := rr.Header().Get("Content-Type")
			if ct != "application/json" {
				t.Errorf("%s %s: Content-Type want application/json, got %q", ep.method, ep.path, ct)
			}
		})
	}
}
