// Package api provides HTTP handler stubs for the agentex coordinator API.
// All endpoints currently return 501 Not Implemented — they are ready for
// incremental implementation (issue #1825, #1827).
package api

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/pnz1990/agentex/coordinator/internal/db"
	"github.com/pnz1990/agentex/coordinator/internal/models"
)

// Handler holds the shared dependencies for all API handlers.
type Handler struct {
	db        *db.DB
	startTime time.Time
}

// New creates a Handler with the given database.
func New(database *db.DB) *Handler {
	return &Handler{
		db:        database,
		startTime: time.Now(),
	}
}

// RegisterRoutes registers all coordinator API routes on mux.
func (h *Handler) RegisterRoutes(mux *http.ServeMux) {
	// Health
	mux.HandleFunc("GET /health", h.Health)

	// Tasks
	mux.HandleFunc("GET /api/tasks", h.ListTasks)
	mux.HandleFunc("POST /api/tasks", h.CreateTask)
	mux.HandleFunc("POST /api/tasks/claim", h.ClaimTask)
	mux.HandleFunc("GET /api/tasks/{id}", h.GetTask)
	mux.HandleFunc("PATCH /api/tasks/{id}", h.UpdateTask)

	// Agents
	mux.HandleFunc("GET /api/agents", h.ListAgents)
	mux.HandleFunc("POST /api/agents/register", h.RegisterAgent)
	mux.HandleFunc("POST /api/agents/heartbeat", h.AgentHeartbeat)
	mux.HandleFunc("GET /api/agents/{name}", h.GetAgent)

	// Governance
	mux.HandleFunc("GET /api/proposals", h.ListProposals)
	mux.HandleFunc("POST /api/proposals", h.CreateProposal)
	mux.HandleFunc("POST /api/proposals/{id}/vote", h.VoteOnProposal)

	// Spawn slots (circuit breaker)
	mux.HandleFunc("POST /api/spawn/acquire", h.AcquireSpawnSlot)
	mux.HandleFunc("POST /api/spawn/release", h.ReleaseSpawnSlot)
	mux.HandleFunc("GET /api/spawn/slots", h.GetSpawnSlots)

	// Debate outcomes
	mux.HandleFunc("GET /api/debates", h.ListDebates)
	mux.HandleFunc("POST /api/debates", h.RecordDebateOutcome)
}

// Health returns 200 with coordinator status. This is the only implemented endpoint.
func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	dbOK := h.db.Ping() == nil
	status := "ok"
	if !dbOK {
		status = "degraded"
		w.WriteHeader(http.StatusServiceUnavailable)
	}

	resp := models.HealthStatus{
		Status:  status,
		DBPing:  dbOK,
		Uptime:  time.Since(h.startTime).Round(time.Second).String(),
	}
	writeJSON(w, http.StatusOK, resp)
}

// --- Task handlers (all stub: 501 Not Implemented) ---

// ListTasks returns all tasks filtered by status.
// GET /api/tasks?status=pending
func (h *Handler) ListTasks(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "ListTasks")
}

// CreateTask adds a task to the work ledger.
// POST /api/tasks {"issue_number": 123, "title": "...", "labels": "bug,enhancement"}
func (h *Handler) CreateTask(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "CreateTask")
}

// ClaimTask atomically claims the next available task for an agent.
// POST /api/tasks/claim {"agent_name": "worker-123", "specialization": "debugger"}
// Uses BEGIN IMMEDIATE transaction to prevent double-claims.
func (h *Handler) ClaimTask(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "ClaimTask")
}

// GetTask returns a single task by ID.
// GET /api/tasks/{id}
func (h *Handler) GetTask(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "GetTask")
}

// UpdateTask updates task status (e.g. mark done/failed).
// PATCH /api/tasks/{id} {"status": "done"}
func (h *Handler) UpdateTask(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "UpdateTask")
}

// --- Agent handlers ---

// ListAgents returns all active agents.
// GET /api/agents
func (h *Handler) ListAgents(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "ListAgents")
}

// RegisterAgent registers a new agent in the work ledger.
// POST /api/agents/register {"name": "worker-123", "role": "worker", "generation": 4}
func (h *Handler) RegisterAgent(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "RegisterAgent")
}

// AgentHeartbeat updates an agent's last_seen_at timestamp.
// POST /api/agents/heartbeat {"agent_name": "worker-123"}
func (h *Handler) AgentHeartbeat(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "AgentHeartbeat")
}

// GetAgent returns a single agent by name.
// GET /api/agents/{name}
func (h *Handler) GetAgent(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "GetAgent")
}

// --- Governance handlers ---

// ListProposals returns open governance proposals.
// GET /api/proposals
func (h *Handler) ListProposals(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "ListProposals")
}

// CreateProposal submits a new governance proposal.
// POST /api/proposals {"topic": "circuit-breaker", "content": "..."}
func (h *Handler) CreateProposal(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "CreateProposal")
}

// VoteOnProposal records a vote on an open proposal.
// POST /api/proposals/{id}/vote {"agent_name": "planner-001", "vote": "approve", "reason": "..."}
func (h *Handler) VoteOnProposal(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "VoteOnProposal")
}

// --- Spawn slot handlers ---

// AcquireSpawnSlot allocates a spawn slot (circuit breaker check).
// POST /api/spawn/acquire {"agent_name": "worker-456"}
func (h *Handler) AcquireSpawnSlot(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "AcquireSpawnSlot")
}

// ReleaseSpawnSlot frees a spawn slot when an agent finishes.
// POST /api/spawn/release {"agent_name": "worker-456"}
func (h *Handler) ReleaseSpawnSlot(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "ReleaseSpawnSlot")
}

// GetSpawnSlots returns current spawn slot counts.
// GET /api/spawn/slots
func (h *Handler) GetSpawnSlots(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "GetSpawnSlots")
}

// --- Debate handlers ---

// ListDebates returns debate outcomes, optionally filtered by topic.
// GET /api/debates?topic=circuit-breaker
func (h *Handler) ListDebates(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "ListDebates")
}

// RecordDebateOutcome persists a debate resolution.
// POST /api/debates {"thread_id": "abc123", "topic": "ttl", "outcome": "synthesized", "resolution": "..."}
func (h *Handler) RecordDebateOutcome(w http.ResponseWriter, r *http.Request) {
	notImplemented(w, "RecordDebateOutcome")
}

// --- helpers ---

type notImplementedResponse struct {
	Error    string `json:"error"`
	Endpoint string `json:"endpoint"`
}

func notImplemented(w http.ResponseWriter, endpoint string) {
	writeJSON(w, http.StatusNotImplemented, notImplementedResponse{
		Error:    "not implemented",
		Endpoint: endpoint,
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
