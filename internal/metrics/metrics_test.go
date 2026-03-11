package metrics

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCounter_Inc(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("test_total", "Test counter")

	c.Inc()
	c.Inc()
	c.Inc()

	if got := c.GetValue(); got != 3 {
		t.Errorf("counter value = %g, want 3", got)
	}
}

func TestCounter_Add(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("test_total", "Test counter")

	c.Add(5)
	c.Add(3.5)

	if got := c.GetValue(); got != 8.5 {
		t.Errorf("counter value = %g, want 8.5", got)
	}
}

func TestCounter_Labels(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("http_requests_total", "HTTP requests")

	c.Inc("method", "GET", "status", "200")
	c.Inc("method", "GET", "status", "200")
	c.Inc("method", "POST", "status", "201")

	if got := c.GetValue("method", "GET", "status", "200"); got != 2 {
		t.Errorf("GET/200 = %g, want 2", got)
	}
	if got := c.GetValue("method", "POST", "status", "201"); got != 1 {
		t.Errorf("POST/201 = %g, want 1", got)
	}
	if got := c.GetValue("method", "DELETE", "status", "404"); got != 0 {
		t.Errorf("DELETE/404 = %g, want 0", got)
	}
}

func TestGauge_Set(t *testing.T) {
	r := NewRegistry()
	g := r.NewGauge("active_agents", "Active agents")

	g.Set(5)
	if got := g.GetValue(); got != 5 {
		t.Errorf("gauge = %g, want 5", got)
	}

	g.Set(3)
	if got := g.GetValue(); got != 3 {
		t.Errorf("gauge = %g, want 3", got)
	}
}

func TestGauge_IncDec(t *testing.T) {
	r := NewRegistry()
	g := r.NewGauge("active_agents", "Active agents")

	g.Inc()
	g.Inc()
	g.Dec()

	if got := g.GetValue(); got != 1 {
		t.Errorf("gauge = %g, want 1", got)
	}
}

func TestGauge_Labels(t *testing.T) {
	r := NewRegistry()
	g := r.NewGauge("agent_count", "Agents by role")

	g.Set(3, "role", "operator")
	g.Set(1, "role", "foreman")
	g.Set(2, "role", "inspector")

	if got := g.GetValue("role", "operator"); got != 3 {
		t.Errorf("operator = %g, want 3", got)
	}
	if got := g.GetValue("role", "foreman"); got != 1 {
		t.Errorf("foreman = %g, want 1", got)
	}
}

func TestRegistry_Handler(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("test_requests_total", "Total requests")
	g := r.NewGauge("test_active_agents", "Active agents count")

	c.Inc()
	c.Inc()
	g.Set(5)

	handler := r.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	resp := rec.Result()
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}

	content := string(body)

	// Check content type
	ct := resp.Header.Get("Content-Type")
	if !strings.Contains(ct, "text/plain") {
		t.Errorf("content-type = %q, want text/plain", ct)
	}

	// Check counter output
	if !strings.Contains(content, "# TYPE test_requests_total counter") {
		t.Error("missing counter TYPE line")
	}
	if !strings.Contains(content, "test_requests_total 2") {
		t.Errorf("missing counter value in output:\n%s", content)
	}

	// Check gauge output
	if !strings.Contains(content, "# TYPE test_active_agents gauge") {
		t.Error("missing gauge TYPE line")
	}
	if !strings.Contains(content, "test_active_agents 5") {
		t.Errorf("missing gauge value in output:\n%s", content)
	}

	// Check uptime metric
	if !strings.Contains(content, "agentex_uptime_seconds") {
		t.Error("missing uptime metric")
	}

	// Check HELP lines
	if !strings.Contains(content, "# HELP test_requests_total Total requests") {
		t.Error("missing counter HELP line")
	}
	if !strings.Contains(content, "# HELP test_active_agents Active agents count") {
		t.Error("missing gauge HELP line")
	}
}

func TestRegistry_Handler_WithLabels(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("http_requests_total", "HTTP requests")

	c.Inc("method", "GET", "code", "200")
	c.Add(3, "method", "POST", "code", "201")

	handler := r.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	body, _ := io.ReadAll(rec.Result().Body)
	content := string(body)

	if !strings.Contains(content, `method="GET"`) {
		t.Errorf("missing GET label in output:\n%s", content)
	}
	if !strings.Contains(content, `method="POST"`) {
		t.Errorf("missing POST label in output:\n%s", content)
	}
}

func TestLabelKey(t *testing.T) {
	tests := []struct {
		labels []string
		want   string
	}{
		{nil, ""},
		{[]string{}, ""},
		{[]string{"odd"}, ""}, // odd number of labels
		{[]string{"role", "operator"}, `role="operator"`},
		{[]string{"role", "operator", "status", "active"}, `role="operator",status="active"`},
	}

	for _, tt := range tests {
		got := labelKey(tt.labels)
		if got != tt.want {
			t.Errorf("labelKey(%v) = %q, want %q", tt.labels, got, tt.want)
		}
	}
}

func TestCounter_ConcurrentAccess(t *testing.T) {
	r := NewRegistry()
	c := r.NewCounter("concurrent_total", "Concurrent test")

	done := make(chan struct{})
	for i := 0; i < 100; i++ {
		go func() {
			c.Inc()
			done <- struct{}{}
		}()
	}
	for i := 0; i < 100; i++ {
		<-done
	}

	if got := c.GetValue(); got != 100 {
		t.Errorf("counter = %g, want 100", got)
	}
}

func TestGauge_ConcurrentAccess(t *testing.T) {
	r := NewRegistry()
	g := r.NewGauge("concurrent_gauge", "Concurrent test")

	done := make(chan struct{})
	for i := 0; i < 50; i++ {
		go func() {
			g.Inc()
			done <- struct{}{}
		}()
	}
	for i := 0; i < 50; i++ {
		<-done
	}
	for i := 0; i < 20; i++ {
		go func() {
			g.Dec()
			done <- struct{}{}
		}()
	}
	for i := 0; i < 20; i++ {
		<-done
	}

	if got := g.GetValue(); got != 30 {
		t.Errorf("gauge = %g, want 30", got)
	}
}

func TestRegistry_EmptyOutput(t *testing.T) {
	r := NewRegistry()

	handler := r.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	body, _ := io.ReadAll(rec.Result().Body)
	content := string(body)

	// Should still have uptime
	if !strings.Contains(content, "agentex_uptime_seconds") {
		t.Error("empty registry should still have uptime metric")
	}
}
