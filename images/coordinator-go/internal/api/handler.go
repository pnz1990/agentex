// Package api provides the HTTP API for the agentex coordinator.
// Agents communicate with the coordinator via this API instead of
// direct ConfigMap CAS operations.
package api

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/pnz1990/agentex/coordinator/internal/state"
)

// Handler is the HTTP API handler for the coordinator.
type Handler struct {
	db     *state.DB
	logger *slog.Logger
}

// New creates a new API handler.
func New(db *state.DB, logger *slog.Logger) *Handler {
	return &Handler{db: db, logger: logger}
}

// RegisterRoutes registers all API routes on the given mux.
func (h *Handler) RegisterRoutes(mux *http.ServeMux) {
	// Health and status
	mux.HandleFunc("GET /healthz", h.handleHealthz)
	mux.HandleFunc("GET /readyz", h.handleReadyz)
	mux.HandleFunc("GET /status", h.handleStatus)

	// Task queue management
	mux.HandleFunc("GET /tasks", h.handleGetTasks)
	mux.HandleFunc("POST /tasks/claim", h.handleClaimTask)
	mux.HandleFunc("POST /tasks/release", h.handleReleaseTask)
	mux.HandleFunc("POST /tasks/heartbeat", h.handleHeartbeat)
	mux.HandleFunc("GET /tasks/assignments", h.handleGetAssignments)

	// Governance
	mux.HandleFunc("POST /votes", h.handleRecordVote)
	mux.HandleFunc("GET /votes/{topic}", h.handleGetVotes)
	mux.HandleFunc("GET /decisions", h.handleGetDecisions)

	// Debate outcomes
	mux.HandleFunc("POST /debates", h.handleRecordDebate)
	mux.HandleFunc("GET /debates", h.handleQueryDebates)

	// Spawn control
	mux.HandleFunc("POST /spawn/request", h.handleSpawnRequest)
	mux.HandleFunc("POST /spawn/release", h.handleSpawnRelease)
	mux.HandleFunc("GET /spawn/slots", h.handleGetSpawnSlots)

	// Agent registration and stats
	mux.HandleFunc("POST /agents/register", h.handleRegisterAgent)
	mux.HandleFunc("POST /agents/report", h.handleAgentReport)
}

// ─── Health ──────────────────────────────────────────────────────────────────

func (h *Handler) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "ok")
}

func (h *Handler) handleReadyz(w http.ResponseWriter, r *http.Request) {
	// Check DB connectivity
	if _, err := h.db.GetAvailableSpawnSlots(); err != nil {
		h.writeError(w, http.StatusServiceUnavailable, "db not ready: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "ready")
}

func (h *Handler) handleStatus(w http.ResponseWriter, r *http.Request) {
	tasks, _ := h.db.GetQueuedTasks(100)
	assignments, _ := h.db.GetActiveAssignments()
	slots, _ := h.db.GetAvailableSpawnSlots()
	debateStats, _ := h.db.GetDebateStats()
	decisions, _ := h.db.GetDecisions(5)

	status := map[string]interface{}{
		"timestamp":       time.Now().UTC().Format(time.RFC3339),
		"queuedTasks":     len(tasks),
		"activeAgents":    len(assignments),
		"spawnSlotsAvail": slots,
		"debateStats":     debateStats,
		"recentDecisions": decisions,
	}
	h.writeJSON(w, http.StatusOK, status)
}

// ─── Tasks ───────────────────────────────────────────────────────────────────

func (h *Handler) handleGetTasks(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 {
			limit = n
		}
	}
	tasks, err := h.db.GetQueuedTasks(limit)
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.writeJSON(w, http.StatusOK, tasks)
}

// ClaimRequest is the request body for POST /tasks/claim.
type ClaimRequest struct {
	AgentName   string `json:"agentName"`
	IssueNumber int    `json:"issueNumber"`
}

// ClaimResponse is the response for POST /tasks/claim.
type ClaimResponse struct {
	Claimed bool   `json:"claimed"`
	Reason  string `json:"reason,omitempty"`
}

func (h *Handler) handleClaimTask(w http.ResponseWriter, r *http.Request) {
	var req ClaimRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if req.AgentName == "" || req.IssueNumber == 0 {
		h.writeError(w, http.StatusBadRequest, "agentName and issueNumber required")
		return
	}

	claimed, err := h.db.ClaimTask(req.AgentName, req.IssueNumber)
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	resp := ClaimResponse{Claimed: claimed}
	if !claimed {
		resp.Reason = "task already claimed or not available"
	}
	h.logger.Info("task claim", "agent", req.AgentName, "issue", req.IssueNumber, "claimed", claimed)
	h.writeJSON(w, http.StatusOK, resp)
}

// ReleaseRequest is the request body for POST /tasks/release.
type ReleaseRequest struct {
	AgentName   string `json:"agentName"`
	IssueNumber int    `json:"issueNumber"`
}

func (h *Handler) handleReleaseTask(w http.ResponseWriter, r *http.Request) {
	var req ReleaseRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}

	if err := h.db.ReleaseTask(req.AgentName, req.IssueNumber); err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	// Return spawn slot
	_ = h.db.ReleaseSpawnSlot()

	h.logger.Info("task released", "agent", req.AgentName, "issue", req.IssueNumber)
	h.writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HeartbeatRequest is the request body for POST /tasks/heartbeat.
type HeartbeatRequest struct {
	AgentName   string `json:"agentName"`
	IssueNumber int    `json:"issueNumber"`
}

func (h *Handler) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	var req HeartbeatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}

	if err := h.db.UpdateAssignmentHeartbeat(req.AgentName, req.IssueNumber); err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handler) handleGetAssignments(w http.ResponseWriter, r *http.Request) {
	assignments, err := h.db.GetActiveAssignments()
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.writeJSON(w, http.StatusOK, assignments)
}

// ─── Governance ──────────────────────────────────────────────────────────────

// VoteRequest is the request body for POST /votes.
type VoteRequest struct {
	Topic     string `json:"topic"`
	AgentName string `json:"agentName"`
	Stance    string `json:"stance"`
	Value     string `json:"value,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

func (h *Handler) handleRecordVote(w http.ResponseWriter, r *http.Request) {
	var req VoteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if req.Topic == "" || req.AgentName == "" || req.Stance == "" {
		h.writeError(w, http.StatusBadRequest, "topic, agentName, and stance required")
		return
	}

	vote := &state.Vote{
		Topic:     req.Topic,
		AgentName: req.AgentName,
		Stance:    req.Stance,
		Value:     req.Value,
		Reason:    req.Reason,
	}
	if err := h.db.RecordVote(vote); err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	approveCount, _ := h.db.CountApproveVotes(req.Topic)
	h.logger.Info("vote recorded", "topic", req.Topic, "agent", req.AgentName, "stance", req.Stance, "approveCount", approveCount)
	h.writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":       "ok",
		"approveCount": approveCount,
	})
}

func (h *Handler) handleGetVotes(w http.ResponseWriter, r *http.Request) {
	topic := r.PathValue("topic")
	votes, err := h.db.GetVotesByTopic(topic)
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.writeJSON(w, http.StatusOK, votes)
}

func (h *Handler) handleGetDecisions(w http.ResponseWriter, r *http.Request) {
	limit := 20
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 {
			limit = n
		}
	}
	decisions, err := h.db.GetDecisions(limit)
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.writeJSON(w, http.StatusOK, decisions)
}

// ─── Debates ─────────────────────────────────────────────────────────────────

// DebateRequest is the request body for POST /debates.
type DebateRequest struct {
	ThreadID     string   `json:"threadId"`
	Topic        string   `json:"topic"`
	Outcome      string   `json:"outcome"`
	Resolution   string   `json:"resolution"`
	Participants []string `json:"participants"`
	RecordedBy   string   `json:"recordedBy"`
}

func (h *Handler) handleRecordDebate(w http.ResponseWriter, r *http.Request) {
	var req DebateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if req.ThreadID == "" || req.Topic == "" {
		h.writeError(w, http.StatusBadRequest, "threadId and topic required")
		return
	}

	participantsJSON, _ := json.Marshal(req.Participants)
	outcome := &state.DebateOutcome{
		ThreadID:     req.ThreadID,
		Topic:        req.Topic,
		Outcome:      req.Outcome,
		Resolution:   req.Resolution,
		Participants: string(participantsJSON),
		RecordedBy:   req.RecordedBy,
	}
	if err := h.db.RecordDebateOutcome(outcome); err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	h.logger.Info("debate recorded", "threadId", req.ThreadID, "topic", req.Topic, "outcome", req.Outcome)
	h.writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handler) handleQueryDebates(w http.ResponseWriter, r *http.Request) {
	topic := r.URL.Query().Get("topic")
	outcomes, err := h.db.QueryDebatesByTopic(topic)
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.writeJSON(w, http.StatusOK, outcomes)
}

// ─── Spawn Control ───────────────────────────────────────────────────────────

// SpawnRequest is the request body for POST /spawn/request.
type SpawnRequest struct {
	AgentName string `json:"agentName"`
	Role      string `json:"role"`
	Reason    string `json:"reason,omitempty"`
}

// SpawnResponse is the response for POST /spawn/request.
type SpawnResponse struct {
	Granted bool   `json:"granted"`
	Reason  string `json:"reason,omitempty"`
	Slots   int    `json:"slotsRemaining"`
}

func (h *Handler) handleSpawnRequest(w http.ResponseWriter, r *http.Request) {
	var req SpawnRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if req.AgentName == "" || req.Role == "" {
		h.writeError(w, http.StatusBadRequest, "agentName and role required")
		return
	}

	granted, err := h.db.RequestSpawnSlot()
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	slots, _ := h.db.GetAvailableSpawnSlots()
	resp := SpawnResponse{Granted: granted, Slots: slots}
	if !granted {
		resp.Reason = "circuit breaker: no spawn slots available"
	}

	h.logger.Info("spawn request", "agent", req.AgentName, "role", req.Role, "granted", granted, "slots", slots)
	statusCode := http.StatusOK
	if !granted {
		statusCode = http.StatusTooManyRequests
	}
	h.writeJSON(w, statusCode, resp)
}

func (h *Handler) handleSpawnRelease(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AgentName string `json:"agentName"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}

	if err := h.db.ReleaseSpawnSlot(); err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	slots, _ := h.db.GetAvailableSpawnSlots()
	h.writeJSON(w, http.StatusOK, map[string]interface{}{"status": "ok", "slotsAvailable": slots})
}

func (h *Handler) handleGetSpawnSlots(w http.ResponseWriter, r *http.Request) {
	slots, err := h.db.GetAvailableSpawnSlots()
	if err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.writeJSON(w, http.StatusOK, map[string]int{"available": slots})
}

// ─── Agent Registration ───────────────────────────────────────────────────────

// RegisterRequest is the request body for POST /agents/register.
type RegisterRequest struct {
	AgentName      string `json:"agentName"`
	Role           string `json:"role"`
	Generation     int    `json:"generation"`
	Specialization string `json:"specialization,omitempty"`
}

func (h *Handler) handleRegisterAgent(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}

	stats := &state.AgentStats{
		AgentName:      req.AgentName,
		Role:           req.Role,
		Generation:     req.Generation,
		Specialization: req.Specialization,
	}
	if err := h.db.UpsertAgentStats(stats); err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	h.logger.Info("agent registered", "agent", req.AgentName, "role", req.Role, "generation", req.Generation)
	h.writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ReportRequest is the request body for POST /agents/report.
type ReportRequest struct {
	AgentName   string  `json:"agentName"`
	Role        string  `json:"role"`
	Generation  int     `json:"generation"`
	VisionScore float64 `json:"visionScore"`
	TasksDone   int     `json:"tasksDone"`
	PRsOpened   int     `json:"prsOpened"`
	DebateCount int     `json:"debateCount"`
	Specialization string `json:"specialization,omitempty"`
}

func (h *Handler) handleAgentReport(w http.ResponseWriter, r *http.Request) {
	var req ReportRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}

	stats := &state.AgentStats{
		AgentName:      req.AgentName,
		Role:           req.Role,
		Generation:     req.Generation,
		VisionScore:    req.VisionScore,
		TasksDone:      req.TasksDone,
		PRsOpened:      req.PRsOpened,
		DebateCount:    req.DebateCount,
		Specialization: req.Specialization,
	}
	if err := h.db.UpsertAgentStats(stats); err != nil {
		h.writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	// Release the spawn slot now that this agent is done
	_ = h.db.ReleaseSpawnSlot()

	h.logger.Info("agent report received", "agent", req.AgentName, "visionScore", req.VisionScore)
	h.writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

func (h *Handler) writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		h.logger.Error("failed to encode response", "error", err)
	}
}

func (h *Handler) writeError(w http.ResponseWriter, code int, msg string) {
	h.writeJSON(w, code, map[string]string{"error": msg})
}
