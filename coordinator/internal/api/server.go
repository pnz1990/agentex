// Package api implements the HTTP API for the Go coordinator.
//
// This replaces the ConfigMap-based communication between agents and coordinator
// with a proper REST API. Agents call these endpoints instead of patching ConfigMaps.
//
// Endpoints:
//   GET  /healthz              — liveness probe
//   GET  /readyz               — readiness probe
//   GET  /status               — civilization overview
//   POST /tasks/claim          — atomically claim a task
//   POST /tasks/release        — mark task done/failed
//   GET  /tasks/pending        — list pending tasks
//   POST /agents/register      — register agent heartbeat
//   POST /agents/deregister    — mark agent inactive
//   POST /spawn/request        — request spawn slot (circuit breaker)
//   POST /spawn/release        — release spawn slot
//   POST /votes                — record a vote
//   GET  /votes/:topic/tally   — get vote tally for topic
//   POST /proposals            — create a governance proposal
//   POST /debates              — record debate outcome
//   GET  /debates              — query debate outcomes
//   POST /reports              — file an agent report (forwarded to k8s)
//   POST /thoughts             — post a thought (forwarded to k8s)
package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/gorilla/mux"
	"go.uber.org/zap"

	"github.com/pnz1990/agentex/coordinator/internal/config"
	"github.com/pnz1990/agentex/coordinator/internal/store"
	"github.com/pnz1990/agentex/coordinator/pkg/types"
)

// Server holds all dependencies for the HTTP API.
type Server struct {
	store  *store.Store
	config *config.Config
	log    *zap.Logger
	router *mux.Router
	startedAt time.Time
}

// New creates a new API server with all routes registered.
func New(s *store.Store, cfg *config.Config, log *zap.Logger) *Server {
	srv := &Server{
		store:     s,
		config:    cfg,
		log:       log,
		startedAt: time.Now(),
	}
	srv.router = srv.buildRouter()
	return srv
}

// ServeHTTP implements http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.router.ServeHTTP(w, r)
}

func (s *Server) buildRouter() *mux.Router {
	r := mux.NewRouter()

	// Probes
	r.HandleFunc("/healthz", s.handleHealthz).Methods(http.MethodGet)
	r.HandleFunc("/readyz", s.handleReadyz).Methods(http.MethodGet)

	// Status
	r.HandleFunc("/status", s.handleStatus).Methods(http.MethodGet)

	// Task operations
	r.HandleFunc("/tasks/claim", s.handleClaimTask).Methods(http.MethodPost)
	r.HandleFunc("/tasks/release", s.handleReleaseTask).Methods(http.MethodPost)
	r.HandleFunc("/tasks/pending", s.handleListPendingTasks).Methods(http.MethodGet)

	// Agent registration
	r.HandleFunc("/agents/register", s.handleRegisterAgent).Methods(http.MethodPost)
	r.HandleFunc("/agents/deregister", s.handleDeregisterAgent).Methods(http.MethodPost)

	// Spawn control
	r.HandleFunc("/spawn/request", s.handleSpawnRequest).Methods(http.MethodPost)
	r.HandleFunc("/spawn/release", s.handleSpawnRelease).Methods(http.MethodPost)

	// Governance
	r.HandleFunc("/votes", s.handleRecordVote).Methods(http.MethodPost)
	r.HandleFunc("/votes/{topic}/tally", s.handleVoteTally).Methods(http.MethodGet)
	r.HandleFunc("/proposals", s.handleCreateProposal).Methods(http.MethodPost)

	// Debates
	r.HandleFunc("/debates", s.handleRecordDebate).Methods(http.MethodPost)
	r.HandleFunc("/debates", s.handleQueryDebates).Methods(http.MethodGet)

	return r
}

// ─── Probes ───────────────────────────────────────────────────────────────────

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	// Check DB is accessible
	if _, err := s.store.GetActiveAgentCount(); err != nil {
		s.writeError(w, http.StatusServiceUnavailable, "database unavailable", err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
}

// ─── Status ───────────────────────────────────────────────────────────────────

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	activeAgents, err := s.store.GetActiveAgentCount()
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "get agent count failed", err.Error())
		return
	}

	activeSpawns, err := s.store.GetActiveSpawnCount()
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "get spawn count failed", err.Error())
		return
	}

	pending, err := s.store.ListPendingTasks(100)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "list tasks failed", err.Error())
		return
	}

	cfg := s.config.Snapshot()
	status := types.CivilizationStatus{
		ActiveAgents:        activeAgents,
		ActiveJobs:          activeSpawns,
		CircuitBreakerLimit: cfg.CircuitBreakerLimit,
		CircuitBreakerOpen:  s.config.CircuitBreakerOpen(activeSpawns),
		TaskQueueSize:       len(pending),
		LastHeartbeat:       time.Now(),
	}

	s.writeJSON(w, http.StatusOK, status)
}

// ─── Task Operations ──────────────────────────────────────────────────────────

func (s *Server) handleClaimTask(w http.ResponseWriter, r *http.Request) {
	var req types.TaskClaimRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}
	if req.AgentName == "" || req.IssueNumber == 0 {
		s.writeError(w, http.StatusBadRequest, "agent_name and issue_number required", "")
		return
	}

	task, claimed, err := s.store.ClaimTask(req.IssueNumber, req.AgentName)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "claim task failed", err.Error())
		return
	}

	resp := types.TaskClaimResponse{
		Claimed: claimed,
		Task:    task,
	}
	if !claimed {
		resp.Reason = "task not available (already claimed or not in queue)"
	}

	s.log.Info("task claim",
		zap.Int("issue", req.IssueNumber),
		zap.String("agent", req.AgentName),
		zap.Bool("claimed", claimed),
	)
	s.writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleReleaseTask(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AgentName   string `json:"agent_name"`
		IssueNumber int    `json:"issue_number"`
		Status      string `json:"status"` // done|failed
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}

	status := types.TaskStatusDone
	if req.Status == "failed" {
		status = types.TaskStatusFailed
	}

	if err := s.store.ReleaseTask(req.IssueNumber, req.AgentName, status); err != nil {
		s.writeError(w, http.StatusInternalServerError, "release task failed", err.Error())
		return
	}

	s.log.Info("task released",
		zap.Int("issue", req.IssueNumber),
		zap.String("agent", req.AgentName),
		zap.String("status", string(status)),
	)
	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleListPendingTasks(w http.ResponseWriter, r *http.Request) {
	limitStr := r.URL.Query().Get("limit")
	limit := 20
	if limitStr != "" {
		if n, err := strconv.Atoi(limitStr); err == nil && n > 0 {
			limit = n
		}
	}

	tasks, err := s.store.ListPendingTasks(limit)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "list tasks failed", err.Error())
		return
	}

	s.writeJSON(w, http.StatusOK, tasks)
}

// ─── Agent Operations ─────────────────────────────────────────────────────────

func (s *Server) handleRegisterAgent(w http.ResponseWriter, r *http.Request) {
	var agent types.Agent
	if err := json.NewDecoder(r.Body).Decode(&agent); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}
	if agent.Name == "" {
		s.writeError(w, http.StatusBadRequest, "agent name required", "")
		return
	}

	if err := s.store.UpsertAgent(&agent); err != nil {
		s.writeError(w, http.StatusInternalServerError, "register agent failed", err.Error())
		return
	}

	s.log.Info("agent registered",
		zap.String("name", agent.Name),
		zap.String("role", string(agent.Role)),
	)
	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleDeregisterAgent(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AgentName string `json:"agent_name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}

	if err := s.store.MarkAgentInactive(req.AgentName); err != nil {
		s.writeError(w, http.StatusInternalServerError, "deregister failed", err.Error())
		return
	}

	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ─── Spawn Control ────────────────────────────────────────────────────────────

func (s *Server) handleSpawnRequest(w http.ResponseWriter, r *http.Request) {
	var req types.SpawnRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}

	cfg := s.config.Snapshot()

	// Check kill switch first
	if cfg.KillSwitchEnabled {
		s.log.Warn("spawn blocked by kill switch",
			zap.String("agent", req.AgentName),
			zap.String("reason", cfg.KillSwitchReason),
		)
		s.writeJSON(w, http.StatusOK, types.SpawnResponse{
			Allowed: false,
			Reason:  "kill switch active: " + cfg.KillSwitchReason,
		})
		return
	}

	allowed, err := s.store.AllocateSpawnSlot(req.AgentName, string(req.Role), cfg.CircuitBreakerLimit)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "allocate spawn slot failed", err.Error())
		return
	}

	if !allowed {
		activeCount, _ := s.store.GetActiveSpawnCount()
		s.log.Warn("spawn blocked by circuit breaker",
			zap.String("agent", req.AgentName),
			zap.Int("active", activeCount),
			zap.Int("limit", cfg.CircuitBreakerLimit),
		)
		s.writeJSON(w, http.StatusOK, types.SpawnResponse{
			Allowed: false,
			Reason:  "circuit breaker: active agents at limit",
		})
		return
	}

	s.log.Info("spawn slot allocated",
		zap.String("agent", req.AgentName),
		zap.String("role", string(req.Role)),
	)
	s.writeJSON(w, http.StatusOK, types.SpawnResponse{
		Allowed:   true,
		AgentName: req.AgentName,
	})
}

func (s *Server) handleSpawnRelease(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AgentName string `json:"agent_name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}

	if err := s.store.ReleaseSpawnSlot(req.AgentName); err != nil {
		s.writeError(w, http.StatusInternalServerError, "release spawn slot failed", err.Error())
		return
	}

	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ─── Governance ───────────────────────────────────────────────────────────────

func (s *Server) handleRecordVote(w http.ResponseWriter, r *http.Request) {
	var vote types.Vote
	if err := json.NewDecoder(r.Body).Decode(&vote); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}

	if err := s.store.RecordVote(&vote); err != nil {
		s.writeError(w, http.StatusInternalServerError, "record vote failed", err.Error())
		return
	}

	// Check if threshold reached and enact if so
	approve, _, _, err := s.store.TallyVotes(vote.Topic)
	if err == nil && approve >= s.config.VoteThreshold {
		// TODO: enact proposal — patch constitution ConfigMap, post verdict Thought CR
		s.log.Info("vote threshold reached",
			zap.String("topic", vote.Topic),
			zap.Int("approve", approve),
		)
	}

	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleVoteTally(w http.ResponseWriter, r *http.Request) {
	topic := mux.Vars(r)["topic"]
	approve, reject, abstain, err := s.store.TallyVotes(topic)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "tally votes failed", err.Error())
		return
	}

	s.writeJSON(w, http.StatusOK, map[string]int{
		"approve": approve,
		"reject":  reject,
		"abstain": abstain,
		"total":   approve + reject + abstain,
	})
}

func (s *Server) handleCreateProposal(w http.ResponseWriter, r *http.Request) {
	var p types.Proposal
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}

	if err := s.store.CreateProposal(&p); err != nil {
		s.writeError(w, http.StatusInternalServerError, "create proposal failed", err.Error())
		return
	}

	s.log.Info("proposal created",
		zap.String("topic", p.Topic),
		zap.String("agent", p.AgentName),
	)
	s.writeJSON(w, http.StatusCreated, p)
}

// ─── Debates ──────────────────────────────────────────────────────────────────

func (s *Server) handleRecordDebate(w http.ResponseWriter, r *http.Request) {
	var d types.DebateOutcome
	if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
		s.writeError(w, http.StatusBadRequest, "invalid request body", err.Error())
		return
	}

	if err := s.store.UpsertDebateOutcome(&d); err != nil {
		s.writeError(w, http.StatusInternalServerError, "record debate failed", err.Error())
		return
	}

	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleQueryDebates(w http.ResponseWriter, r *http.Request) {
	topic := r.URL.Query().Get("topic")
	outcomes, err := s.store.QueryDebateOutcomes(topic)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "query debates failed", err.Error())
		return
	}

	if outcomes == nil {
		outcomes = []*types.DebateOutcome{}
	}
	s.writeJSON(w, http.StatusOK, outcomes)
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func (s *Server) writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		s.log.Error("encode response", zap.Error(err))
	}
}

func (s *Server) writeError(w http.ResponseWriter, code int, msg, details string) {
	s.writeJSON(w, code, types.ErrorResponse{Error: msg, Details: details})
}
