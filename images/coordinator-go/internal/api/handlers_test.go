// Package api_test tests the HTTP handlers for the agentex Go coordinator.
// These tests verify that the health endpoint works and all stub endpoints
// return 501 Not Implemented as documented.
package api_test

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/pnz1990/agentex/coordinator/internal/api"
	"github.com/pnz1990/agentex/coordinator/internal/db"
)

// newTestServer creates an httptest.Server backed by an in-memory database.
func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	database, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	t.Cleanup(func() { _ = database.Close() })

	mux := http.NewServeMux()
	h := api.New(database)
	h.RegisterRoutes(mux)
	return httptest.NewServer(mux)
}

// TestHealthOK verifies the /health endpoint returns 200 with an "ok" status.
func TestHealthOK(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("status: got %d, want %d", resp.StatusCode, http.StatusOK)
	}

	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode body: %v", err)
	}

	if body["status"] != "ok" {
		t.Errorf("status field: got %q, want %q", body["status"], "ok")
	}
	if body["db"] != "ok" {
		t.Errorf("db field: got %q, want %q", body["db"], "ok")
	}
	if body["version"] != "0.1.0-skeleton" {
		t.Errorf("version field: got %q, want %q", body["version"], "0.1.0-skeleton")
	}
}

// TestHealthContentType verifies /health returns application/json.
func TestHealthContentType(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer resp.Body.Close()

	ct := resp.Header.Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("Content-Type: got %q, want %q", ct, "application/json")
	}
}

// stubEndpoints lists all stub API endpoints and their HTTP methods.
// These should all return 501 Not Implemented until wired to the database layer.
var stubEndpoints = []struct {
	method string
	path   string
}{
	{http.MethodGet, "/api/tasks"},
	{http.MethodGet, "/api/tasks/42"},
	{http.MethodPost, "/api/tasks/claim"},
	{http.MethodPost, "/api/tasks/release"},
	{http.MethodGet, "/api/agents"},
	{http.MethodGet, "/api/agents/worker-001/activity"},
	{http.MethodGet, "/api/agents/worker-001/stats"},
	{http.MethodGet, "/api/debates"},
	{http.MethodGet, "/api/debates/thread-abc123"},
	{http.MethodPost, "/api/debates"},
	{http.MethodGet, "/api/proposals"},
	{http.MethodPost, "/api/proposals"},
	{http.MethodPost, "/api/proposals/1/vote"},
	{http.MethodGet, "/api/metrics"},
	{http.MethodGet, "/api/metrics/snapshot"},
}

// TestStubEndpointsReturn501 verifies all unimplemented endpoints return 501.
func TestStubEndpointsReturn501(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	client := &http.Client{}

	for _, ep := range stubEndpoints {
		t.Run(ep.method+"_"+ep.path, func(t *testing.T) {
			req, err := http.NewRequest(ep.method, srv.URL+ep.path, nil)
			if err != nil {
				t.Fatalf("new request: %v", err)
			}
			resp, err := client.Do(req)
			if err != nil {
				t.Fatalf("%s %s: %v", ep.method, ep.path, err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusNotImplemented {
				body, _ := io.ReadAll(resp.Body)
				t.Errorf("%s %s: status got %d, want %d (body: %s)",
					ep.method, ep.path, resp.StatusCode, http.StatusNotImplemented, body)
			}

			// Verify error response is valid JSON with "error" field.
			var body map[string]string
			if err := json.NewDecoder(resp.Body).Decode(&body); err == nil {
				if body["error"] == "" {
					t.Errorf("%s %s: response JSON missing 'error' field", ep.method, ep.path)
				}
			}
		})
	}
}

// TestNotFoundRoutes verifies that unknown routes return 404.
func TestNotFoundRoutes(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	notFoundPaths := []string{
		"/api/unknown",
		"/api/tasks/42/subresource",
		"/api/agents/worker-001/unknown",
		"/api/proposals/1/unknown",
	}

	for _, path := range notFoundPaths {
		t.Run(path, func(t *testing.T) {
			resp, err := http.Get(srv.URL + path)
			if err != nil {
				t.Fatalf("GET %s: %v", path, err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusNotFound {
				t.Errorf("GET %s: status got %d, want %d", path, resp.StatusCode, http.StatusNotFound)
			}
		})
	}
}
