// Command coordinator is the agentex Go coordinator — a Kubernetes Deployment
// that replaces coordinator.sh as the civilization's persistent brain.
//
// It serves an HTTP API backed by a SQLite database (PersistentVolume), providing:
//   - Atomic task claiming (no TOCTOU races)
//   - Queryable debate history (no S3 scans)
//   - Typed agent statistics (no ConfigMap string parsing)
//   - Governance proposal/vote lifecycle
//
// This is a skeleton implementation (issue #1932, part of epics #1825/#1827).
// All API handlers return 501 Not Implemented and are ready to be wired up.
//
// Usage:
//
//	coordinator [--db /data/coordinator.db] [--addr :8080]
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/pnz1990/agentex/coordinator/internal/api"
	"github.com/pnz1990/agentex/coordinator/internal/db"
)

func main() {
	// ── Flags / env vars ──────────────────────────────────────────────────
	dbPath := flag.String("db", envOrDefault("COORDINATOR_DB", "/data/coordinator.db"),
		"Path to the SQLite database file")
	addr := flag.String("addr", envOrDefault("COORDINATOR_ADDR", ":8080"),
		"TCP address to listen on")
	flag.Parse()

	// ── Logging ───────────────────────────────────────────────────────────
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC | log.Lshortfile)
	log.Printf("[coordinator] starting (db=%s addr=%s)", *dbPath, *addr)

	// ── Database ──────────────────────────────────────────────────────────
	database, err := db.Open(*dbPath)
	if err != nil {
		log.Fatalf("[coordinator] fatal: open db: %v", err)
	}
	defer func() {
		if cerr := database.Close(); cerr != nil {
			log.Printf("[coordinator] warn: close db: %v", cerr)
		}
	}()

	// ── HTTP server ───────────────────────────────────────────────────────
	mux := http.NewServeMux()
	h := api.New(database)
	h.RegisterRoutes(mux)

	srv := &http.Server{
		Addr:         *addr,
		Handler:      loggingMiddleware(mux),
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	log.Printf("[coordinator] listening on %s", *addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[coordinator] fatal: server: %v", err)
	}
}

// loggingMiddleware logs each HTTP request.
func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(rw, r)
		log.Printf("[http] %s %s %d %s", r.Method, r.URL.Path, rw.status, time.Since(start))
	})
}

// responseWriter wraps http.ResponseWriter to capture the status code.
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

// envOrDefault returns the value of the environment variable named key,
// or def if the variable is not set.
func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
