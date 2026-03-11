// Package api implements the HTTP handlers for the agentex Go coordinator.
// All endpoints defined in epic #1827 are stubbed here, returning 501 Not
// Implemented until they are fully wired to the database layer.
//
// Endpoint catalogue (from #1827):
//
//	GET  /health                       — liveness/readiness probe
//	GET  /api/tasks                    — list tasks with filtering
//	GET  /api/tasks/:id                — task detail
//	POST /api/tasks/claim              — atomic claim
//	POST /api/tasks/release            — release claim
//	GET  /api/agents                   — active agents
//	GET  /api/agents/:name/activity    — agent activity log
//	GET  /api/agents/:name/stats       — completion rate, specialization, etc.
//	GET  /api/debates                  — debate threads
//	GET  /api/debates/:thread          — full debate chain
//	POST /api/debates                  — post debate response
//	GET  /api/proposals                — governance proposals
//	POST /api/proposals                — create proposal
//	POST /api/proposals/:id/vote       — cast vote
//	GET  /api/metrics                  — civilization metrics
//	GET  /api/metrics/snapshot         — current dashboard data
package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/pnz1990/agentex/coordinator/internal/db"
)

// Handler holds the dependencies for all HTTP handlers.
type Handler struct {
	db        *db.DB
	startedAt time.Time
}

// New creates a new Handler with the given database connection.
func New(database *db.DB) *Handler {
	return &Handler{
		db:        database,
		startedAt: time.Now().UTC(),
	}
}

// RegisterRoutes wires all API routes onto mux.
// Uses stdlib ServeMux with manual path routing for query params and URL vars.
func (h *Handler) RegisterRoutes(mux *http.ServeMux) {
	// Health
	mux.HandleFunc("/health", h.Health)

	// Tasks
	mux.HandleFunc("/api/tasks/claim",   h.ClaimTask)
	mux.HandleFunc("/api/tasks/release", h.ReleaseTask)
	mux.HandleFunc("/api/tasks/",        h.tasksRouter)
	mux.HandleFunc("/api/tasks",         h.ListTasks)

	// Agents
	mux.HandleFunc("/api/agents/", h.agentsRouter)
	mux.HandleFunc("/api/agents",  h.ListAgents)

	// Debates
	mux.HandleFunc("/api/debates/", h.debatesRouter)
	mux.HandleFunc("/api/debates",  h.debatesRootRouter)

	// Proposals
	mux.HandleFunc("/api/proposals/", h.proposalsRouter)
	mux.HandleFunc("/api/proposals",  h.proposalsRootRouter)

	// Metrics
	mux.HandleFunc("/api/metrics/snapshot", h.MetricsSnapshot)
	mux.HandleFunc("/api/metrics",          h.ListMetrics)
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func notImplemented(w http.ResponseWriter) {
	writeJSON(w, http.StatusNotImplemented, map[string]string{
		"error": "not yet implemented — see epics #1825 and #1827",
	})
}

// pathSegments splits a URL path into non-empty segments.
// e.g. "/api/tasks/42" → ["api", "tasks", "42"]
func pathSegments(path string) []string {
	var segs []string
	for _, s := range strings.Split(path, "/") {
		if s != "" {
			segs = append(segs, s)
		}
	}
	return segs
}

// ── Routers (manual URL dispatch until we add a real router) ──────────────────

func (h *Handler) tasksRouter(w http.ResponseWriter, r *http.Request) {
	segs := pathSegments(r.URL.Path)
	// /api/tasks/{id}
	if len(segs) == 3 {
		h.GetTask(w, r, segs[2])
		return
	}
	http.NotFound(w, r)
}

func (h *Handler) agentsRouter(w http.ResponseWriter, r *http.Request) {
	segs := pathSegments(r.URL.Path)
	// /api/agents/{name}/activity  or  /api/agents/{name}/stats
	if len(segs) == 4 {
		switch segs[3] {
		case "activity":
			h.GetAgentActivity(w, r, segs[2])
			return
		case "stats":
			h.GetAgentStats(w, r, segs[2])
			return
		}
	}
	http.NotFound(w, r)
}

func (h *Handler) debatesRouter(w http.ResponseWriter, r *http.Request) {
	segs := pathSegments(r.URL.Path)
	// /api/debates/{thread}
	if len(segs) == 3 {
		h.GetDebateThread(w, r, segs[2])
		return
	}
	http.NotFound(w, r)
}

func (h *Handler) debatesRootRouter(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		h.ListDebates(w, r)
	case http.MethodPost:
		h.PostDebate(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (h *Handler) proposalsRouter(w http.ResponseWriter, r *http.Request) {
	segs := pathSegments(r.URL.Path)
	// /api/proposals/{id}/vote
	if len(segs) == 4 && segs[3] == "vote" && r.Method == http.MethodPost {
		h.CastVote(w, r, segs[2])
		return
	}
	http.NotFound(w, r)
}

func (h *Handler) proposalsRootRouter(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		h.ListProposals(w, r)
	case http.MethodPost:
		h.CreateProposal(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// ── Health ────────────────────────────────────────────────────────────────────

// Health returns coordinator liveness status.
// Used by Kubernetes liveness and readiness probes.
func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	uptime := time.Since(h.startedAt).Round(time.Second).String()

	if err := h.db.Ping(); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"status": "unhealthy",
			"db":     "error: " + err.Error(),
			"uptime": uptime,
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "ok",
		"db":      "ok",
		"uptime":  uptime,
		"version": "0.1.0-skeleton",
	})
}

// ── Tasks ─────────────────────────────────────────────────────────────────────

// ListTasks returns tasks, optionally filtered by ?state=queued&source=github.
func (h *Handler) ListTasks(w http.ResponseWriter, r *http.Request) {
	// TODO: query tasks table with optional state/source/priority filters.
	notImplemented(w)
}

// GetTask returns a single task by numeric ID.
func (h *Handler) GetTask(w http.ResponseWriter, r *http.Request, id string) {
	// TODO: SELECT * FROM tasks WHERE id = ?
	notImplemented(w)
}

// ClaimTask atomically claims a task for an agent.
// Uses a BEGIN IMMEDIATE transaction so concurrent claims are serialised.
func (h *Handler) ClaimTask(w http.ResponseWriter, r *http.Request) {
	// TODO: BEGIN IMMEDIATE; UPDATE tasks SET state='claimed', claimed_by=?, claimed_at=now()
	//       WHERE issue_number=? AND state='queued'; COMMIT
	notImplemented(w)
}

// ReleaseTask returns a claimed task to the queue.
func (h *Handler) ReleaseTask(w http.ResponseWriter, r *http.Request) {
	// TODO: UPDATE tasks SET state='queued', claimed_by=NULL WHERE issue_number=? AND claimed_by=?
	notImplemented(w)
}

// ── Agents ────────────────────────────────────────────────────────────────────

// ListAgents returns all agents, optionally filtered by ?role=worker&status=active.
func (h *Handler) ListAgents(w http.ResponseWriter, r *http.Request) {
	// TODO: SELECT * FROM agents WHERE role=? AND status=?
	notImplemented(w)
}

// GetAgentActivity returns the activity log for a specific agent.
func (h *Handler) GetAgentActivity(w http.ResponseWriter, r *http.Request, name string) {
	// TODO: SELECT * FROM agent_activity WHERE agent_name=? ORDER BY created_at DESC LIMIT 100
	notImplemented(w)
}

// GetAgentStats returns summary statistics for a specific agent.
func (h *Handler) GetAgentStats(w http.ResponseWriter, r *http.Request, name string) {
	// TODO: SELECT tasks_completed, prs_merged, synthesis_count, ... FROM agents WHERE name=?
	notImplemented(w)
}

// ── Debates ───────────────────────────────────────────────────────────────────

// ListDebates returns debate threads, optionally filtered by topic or component.
func (h *Handler) ListDebates(w http.ResponseWriter, r *http.Request) {
	// TODO: SELECT DISTINCT thread_id, topic, COUNT(*) AS replies FROM debates GROUP BY thread_id
	notImplemented(w)
}

// GetDebateThread returns the full debate chain for a given thread_id.
// Intended to use a WITH RECURSIVE CTE to reconstruct the parent_id chain.
func (h *Handler) GetDebateThread(w http.ResponseWriter, r *http.Request, thread string) {
	// TODO:
	// WITH RECURSIVE chain(id, parent_id, depth) AS (
	//   SELECT id, parent_id, 0 FROM debates WHERE thread_id=? AND parent_id IS NULL
	//   UNION ALL
	//   SELECT d.id, d.parent_id, c.depth+1 FROM debates d JOIN chain c ON d.parent_id=c.id
	// )
	// SELECT d.* FROM debates d JOIN chain c ON d.id=c.id ORDER BY c.depth, d.created_at
	notImplemented(w)
}

// PostDebate records a new debate response and optionally records a synthesis.
// This replaces the S3 write that helpers.sh does for debate outcomes.
func (h *Handler) PostDebate(w http.ResponseWriter, r *http.Request) {
	// TODO: INSERT INTO debates(thread_id, parent_id, agent_name, stance, content, ...)
	notImplemented(w)
}

// ── Proposals ─────────────────────────────────────────────────────────────────

// ListProposals returns open (or all) governance proposals.
func (h *Handler) ListProposals(w http.ResponseWriter, r *http.Request) {
	// TODO: SELECT * FROM proposals WHERE state=? ORDER BY created_at DESC
	notImplemented(w)
}

// CreateProposal creates a new governance proposal.
func (h *Handler) CreateProposal(w http.ResponseWriter, r *http.Request) {
	// TODO: INSERT INTO proposals(topic, key, value, description, proposed_by, threshold)
	notImplemented(w)
}

// CastVote casts a vote on an existing proposal.
// The trg_proposals_vote_count trigger automatically updates the vote tallies.
func (h *Handler) CastVote(w http.ResponseWriter, r *http.Request, id string) {
	// TODO: INSERT OR IGNORE INTO votes(proposal_id, voter, stance, reason)
	//       Trigger fires → updates proposals.vote_approve/reject/abstain.
	//       If vote_approve >= threshold → enact proposal.
	notImplemented(w)
}

// ── Metrics ───────────────────────────────────────────────────────────────────

// ListMetrics returns all metric names and their totals.
func (h *Handler) ListMetrics(w http.ResponseWriter, r *http.Request) {
	// TODO: SELECT metric, SUM(value), MAX(recorded_at) FROM metrics GROUP BY metric
	notImplemented(w)
}

// MetricsSnapshot returns current civilization dashboard data.
func (h *Handler) MetricsSnapshot(w http.ResponseWriter, r *http.Request) {
	// TODO: Query v_debate_stats view, active agents, queued tasks, enacted proposals.
	notImplemented(w)
}
