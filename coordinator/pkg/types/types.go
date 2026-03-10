// Package types defines the core data structures for the agentex coordinator.
// These replace the string-parsing approach in coordinator.sh with typed Go structs.
package types

import "time"

// TaskStatus represents the lifecycle state of a task.
type TaskStatus string

const (
	TaskStatusPending    TaskStatus = "pending"
	TaskStatusClaimed    TaskStatus = "claimed"
	TaskStatusInProgress TaskStatus = "in_progress"
	TaskStatusDone       TaskStatus = "done"
	TaskStatusFailed     TaskStatus = "failed"
)

// AgentRole defines what an agent is responsible for.
type AgentRole string

const (
	RolePlanner      AgentRole = "planner"
	RoleWorker       AgentRole = "worker"
	RoleReviewer     AgentRole = "reviewer"
	RoleArchitect    AgentRole = "architect"
	RoleCritic       AgentRole = "critic"
	RoleGodDelegate  AgentRole = "god-delegate"
)

// Task represents a unit of work assigned to an agent.
// Replaces the comma-separated taskQueue in coordinator-state ConfigMap.
type Task struct {
	ID          int64      `json:"id" db:"id"`
	IssueNumber int        `json:"issue_number" db:"issue_number"`
	Title       string     `json:"title" db:"title"`
	Labels      string     `json:"labels" db:"labels"` // comma-separated
	Priority    int        `json:"priority" db:"priority"`
	Status      TaskStatus `json:"status" db:"status"`
	AgentName   string     `json:"agent_name,omitempty" db:"agent_name"`
	ClaimedAt   *time.Time `json:"claimed_at,omitempty" db:"claimed_at"`
	CompletedAt *time.Time `json:"completed_at,omitempty" db:"completed_at"`
	CreatedAt   time.Time  `json:"created_at" db:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at" db:"updated_at"`
}

// Agent represents an active agent in the civilization.
// Replaces the activeAgents comma-separated string in coordinator-state.
type Agent struct {
	ID           int64     `json:"id" db:"id"`
	Name         string    `json:"name" db:"name"`
	Role         AgentRole `json:"role" db:"role"`
	Generation   int       `json:"generation" db:"generation"`
	DisplayName  string    `json:"display_name,omitempty" db:"display_name"`
	Specialization string  `json:"specialization,omitempty" db:"specialization"`
	RegisteredAt time.Time `json:"registered_at" db:"registered_at"`
	LastSeenAt   time.Time `json:"last_seen_at" db:"last_seen_at"`
	Active       bool      `json:"active" db:"active"`
}

// VoteStatus represents possible vote values.
type VoteStatus string

const (
	VoteApprove VoteStatus = "approve"
	VoteReject  VoteStatus = "reject"
	VoteAbstain VoteStatus = "abstain"
)

// Vote records an agent's vote on a proposal.
// Replaces the voteRegistry string in coordinator-state.
type Vote struct {
	ID         int64      `json:"id" db:"id"`
	Topic      string     `json:"topic" db:"topic"`
	ProposalID string     `json:"proposal_id" db:"proposal_id"` // thought ConfigMap name
	AgentName  string     `json:"agent_name" db:"agent_name"`
	Status     VoteStatus `json:"status" db:"status"`
	Value      string     `json:"value,omitempty" db:"value"` // e.g. circuitBreakerLimit=12
	Reason     string     `json:"reason,omitempty" db:"reason"`
	CreatedAt  time.Time  `json:"created_at" db:"created_at"`
}

// Proposal represents a governance proposal.
type Proposal struct {
	ID        int64     `json:"id" db:"id"`
	Topic     string    `json:"topic" db:"topic"`
	AgentName string    `json:"agent_name" db:"agent_name"`
	Content   string    `json:"content" db:"content"`
	Key       string    `json:"key,omitempty" db:"key"`     // e.g. "circuitBreakerLimit"
	Value     string    `json:"value,omitempty" db:"value"` // e.g. "12"
	Enacted   bool      `json:"enacted" db:"enacted"`
	EnactedAt *time.Time `json:"enacted_at,omitempty" db:"enacted_at"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

// DebateOutcome records the result of a cross-agent debate.
// Replaces S3 JSON files in agentex-thoughts/debates/*.json
type DebateOutcome struct {
	ID           int64     `json:"id" db:"id"`
	ThreadID     string    `json:"thread_id" db:"thread_id"`
	Topic        string    `json:"topic" db:"topic"`
	Outcome      string    `json:"outcome" db:"outcome"` // synthesized|consensus-agree|unresolved
	Resolution   string    `json:"resolution" db:"resolution"`
	Participants string    `json:"participants" db:"participants"` // JSON array
	RecordedBy   string    `json:"recorded_by" db:"recorded_by"`
	CreatedAt    time.Time `json:"created_at" db:"created_at"`
}

// SpawnRequest represents a request to spawn a new agent.
// Replaces distributed CAS operations in spawn_agent() bash function.
type SpawnRequest struct {
	AgentName   string    `json:"agent_name"`
	Role        AgentRole `json:"role"`
	TaskName    string    `json:"task_name"`
	Description string    `json:"description"`
	Effort      string    `json:"effort"`
	IssueNumber int       `json:"issue_number,omitempty"`
	RequestedBy string    `json:"requested_by"`
}

// SpawnResponse is returned by the coordinator spawn endpoint.
type SpawnResponse struct {
	Allowed    bool   `json:"allowed"`
	AgentName  string `json:"agent_name,omitempty"`
	Reason     string `json:"reason,omitempty"` // if not allowed, why
	SlotNumber int    `json:"slot_number,omitempty"`
}

// TaskClaimRequest is the body for claiming a task.
type TaskClaimRequest struct {
	AgentName string `json:"agent_name"`
	IssueNumber int  `json:"issue_number"`
}

// TaskClaimResponse is returned from the task claim endpoint.
type TaskClaimResponse struct {
	Claimed     bool   `json:"claimed"`
	Task        *Task  `json:"task,omitempty"`
	Reason      string `json:"reason,omitempty"` // if not claimed, why
}

// CivilizationStatus is a summary view of the entire civilization state.
// Returned by GET /status endpoint, replaces civilization_status() bash function.
type CivilizationStatus struct {
	Generation         int       `json:"generation"`
	ActiveAgents       int       `json:"active_agents"`
	ActiveJobs         int       `json:"active_jobs"`
	CircuitBreakerLimit int      `json:"circuit_breaker_limit"`
	CircuitBreakerOpen bool      `json:"circuit_breaker_open"`
	TaskQueueSize      int       `json:"task_queue_size"`
	ActiveAssignments  int       `json:"active_assignments"`
	DebateCount        int       `json:"debate_count"`
	VisionQueue        []string  `json:"vision_queue"`
	EnactedDecisions   []string  `json:"enacted_decisions"`
	LastHeartbeat      time.Time `json:"last_heartbeat"`
}

// ReportRequest is sent by an agent when filing a report.
type ReportRequest struct {
	AgentName   string `json:"agent_name"`
	TaskRef     string `json:"task_ref"`
	Role        string `json:"role"`
	Status      string `json:"status"`
	VisionScore int    `json:"vision_score"`
	WorkDone    string `json:"work_done"`
	IssuesFound string `json:"issues_found"`
	PROpened    string `json:"pr_opened"`
	Blockers    string `json:"blockers"`
	NextPriority string `json:"next_priority"`
	Generation  int    `json:"generation"`
	ExitCode    int    `json:"exit_code"`
}

// ThoughtRequest is sent by an agent when posting a thought.
type ThoughtRequest struct {
	AgentName   string `json:"agent_name"`
	TaskRef     string `json:"task_ref"`
	ThoughtType string `json:"thought_type"` // insight|proposal|vote|debate|blocker|directive
	Confidence  int    `json:"confidence"`
	Content     string `json:"content"`
	ParentRef   string `json:"parent_ref,omitempty"`
	Topic       string `json:"topic,omitempty"`
	FilePath    string `json:"file_path,omitempty"`
}

// ErrorResponse is returned on API errors.
type ErrorResponse struct {
	Error   string `json:"error"`
	Details string `json:"details,omitempty"`
}
