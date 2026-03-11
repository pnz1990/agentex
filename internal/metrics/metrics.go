// Package metrics provides lightweight Prometheus-compatible metrics
// for the agentex coordinator and agents. Uses only stdlib — no external
// Prometheus client dependency. Metrics are exposed in Prometheus text
// exposition format at /metrics.
package metrics

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// Registry holds all registered metrics and exposes them via HTTP.
type Registry struct {
	mu       sync.RWMutex
	counters map[string]*Counter
	gauges   map[string]*Gauge

	startTime time.Time
}

// NewRegistry creates a new metrics registry.
func NewRegistry() *Registry {
	return &Registry{
		counters:  make(map[string]*Counter),
		gauges:    make(map[string]*Gauge),
		startTime: time.Now(),
	}
}

// Counter is a monotonically increasing metric.
type Counter struct {
	name   string
	help   string
	mu     sync.Mutex
	values map[string]float64 // label combo -> value
}

// Gauge is a metric that can go up and down.
type Gauge struct {
	name   string
	help   string
	mu     sync.Mutex
	values map[string]float64 // label combo -> value
}

// NewCounter registers a new counter metric.
func (r *Registry) NewCounter(name, help string) *Counter {
	r.mu.Lock()
	defer r.mu.Unlock()

	c := &Counter{
		name:   name,
		help:   help,
		values: make(map[string]float64),
	}
	r.counters[name] = c
	return c
}

// NewGauge registers a new gauge metric.
func (r *Registry) NewGauge(name, help string) *Gauge {
	r.mu.Lock()
	defer r.mu.Unlock()

	g := &Gauge{
		name:   name,
		help:   help,
		values: make(map[string]float64),
	}
	r.gauges[name] = g
	return g
}

// Inc increments the counter by 1 with the given labels.
func (c *Counter) Inc(labels ...string) {
	c.Add(1, labels...)
}

// Add adds the given value to the counter with the given labels.
func (c *Counter) Add(v float64, labels ...string) {
	key := labelKey(labels)
	c.mu.Lock()
	c.values[key] += v
	c.mu.Unlock()
}

// Set sets the gauge to the given value with the given labels.
func (g *Gauge) Set(v float64, labels ...string) {
	key := labelKey(labels)
	g.mu.Lock()
	g.values[key] = v
	g.mu.Unlock()
}

// Inc increments the gauge by 1 with the given labels.
func (g *Gauge) Inc(labels ...string) {
	g.Add(1, labels...)
}

// Dec decrements the gauge by 1 with the given labels.
func (g *Gauge) Dec(labels ...string) {
	g.Add(-1, labels...)
}

// Add adds the given value to the gauge with the given labels.
func (g *Gauge) Add(v float64, labels ...string) {
	key := labelKey(labels)
	g.mu.Lock()
	g.values[key] += v
	g.mu.Unlock()
}

// GetValue returns the current value for a counter with the given labels.
func (c *Counter) GetValue(labels ...string) float64 {
	key := labelKey(labels)
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.values[key]
}

// GetValue returns the current value for a gauge with the given labels.
func (g *Gauge) GetValue(labels ...string) float64 {
	key := labelKey(labels)
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.values[key]
}

// Handler returns an http.Handler that exposes metrics in Prometheus
// text exposition format.
func (r *Registry) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

		var sb strings.Builder

		r.mu.RLock()
		defer r.mu.RUnlock()

		// Sort names for deterministic output
		counterNames := sortedKeys(r.counters)
		gaugeNames := sortedKeys(r.gauges)

		// Emit counters
		for _, name := range counterNames {
			c := r.counters[name]
			c.mu.Lock()
			if c.help != "" {
				fmt.Fprintf(&sb, "# HELP %s %s\n", c.name, c.help)
			}
			fmt.Fprintf(&sb, "# TYPE %s counter\n", c.name)
			for labelKey, val := range c.values {
				if labelKey == "" {
					fmt.Fprintf(&sb, "%s %g\n", c.name, val)
				} else {
					fmt.Fprintf(&sb, "%s{%s} %g\n", c.name, labelKey, val)
				}
			}
			c.mu.Unlock()
		}

		// Emit gauges
		for _, name := range gaugeNames {
			g := r.gauges[name]
			g.mu.Lock()
			if g.help != "" {
				fmt.Fprintf(&sb, "# HELP %s %s\n", g.name, g.help)
			}
			fmt.Fprintf(&sb, "# TYPE %s gauge\n", g.name)
			for labelKey, val := range g.values {
				if labelKey == "" {
					fmt.Fprintf(&sb, "%s %g\n", g.name, val)
				} else {
					fmt.Fprintf(&sb, "%s{%s} %g\n", g.name, labelKey, val)
				}
			}
			g.mu.Unlock()
		}

		// Built-in: process uptime
		uptime := time.Since(r.startTime).Seconds()
		fmt.Fprintf(&sb, "# HELP agentex_uptime_seconds Time since process start\n")
		fmt.Fprintf(&sb, "# TYPE agentex_uptime_seconds gauge\n")
		fmt.Fprintf(&sb, "agentex_uptime_seconds %g\n", uptime)

		w.Write([]byte(sb.String()))
	})
}

// labelKey converts label pairs to Prometheus label format.
// Labels are passed as alternating key, value pairs: "role", "operator", "status", "active"
// Produces: role="operator",status="active"
func labelKey(labels []string) string {
	if len(labels) == 0 {
		return ""
	}
	if len(labels)%2 != 0 {
		return "" // Invalid: must be key-value pairs
	}
	var parts []string
	for i := 0; i < len(labels); i += 2 {
		parts = append(parts, fmt.Sprintf("%s=%q", labels[i], labels[i+1]))
	}
	return strings.Join(parts, ",")
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
