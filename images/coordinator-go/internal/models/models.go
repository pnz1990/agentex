package models

import "time"

// Task represents an agent work item (replaces coordinator-state.taskQueue + activeAssignments).
type Task struct {
	ID          int64     `db:"id"`
	IssueNumber int       `db:"issue_number"`
	Title       string    `db:"title"`
	Status      string    `db:"status"` // pending, assigned, in_progress, done, failed
	AssignedTo  string    `db:"assigned_to"`
	Priority    int       `db:"priority"`
	Labels      string    `db:"labels"`
	CreatedAt   time.Time `db:"created_at"`
	UpdatedAt   time.Time `db:"updated_at"`
	ClaimedAt   *time.Time `db:"claimed_at"`
	CompletedAt *time.Time `db:"completed_at"`
}

// Agent represents an active or historical agent (replaces coordinator-state.activeAgents + S3 identity files).
type Agent struct {
	ID             int64     `db:"id"`
	Name           string    `db:"name"`         // e.g. worker-1773190398
	DisplayName    string    `db:"display_name"` // e.g. ada
	Role           string    `db:"role"`         // planner, worker, reviewer, architect
	Generation     int       `db:"generation"`
	Specialization string    `db:"specialization"`
	Status         string    `db:"status"` // active, completed, failed
	StartedAt      time.Time `db:"started_at"`
	LastSeenAt     time.Time `db:"last_seen_at"`
	CompletedAt    *time.Time `db:"completed_at"`
}

// Thought represents a Thought CR (in-cluster coordination signal).
type Thought struct {
	ID          int64     `db:"id"`
	Name        string    `db:"name"`
	AgentRef    string    `db:"agent_ref"`
	TaskRef     string    `db:"task_ref"`
	ThoughtType string    `db:"thought_type"` // insight, proposal, vote, debate, directive, blocker
	Confidence  int       `db:"confidence"`
	Content     string    `db:"content"`
	ParentRef   string    `db:"parent_ref"`
	Topic       string    `db:"topic"`
	CreatedAt   time.Time `db:"created_at"`
}

// DebateOutcome represents a resolved debate thread stored in S3.
type DebateOutcome struct {
	ID           int64     `db:"id"`
	ThreadID     string    `db:"thread_id"`
	Topic        string    `db:"topic"`
	Outcome      string    `db:"outcome"` // synthesized, consensus-agree, consensus-disagree, unresolved
	Resolution   string    `db:"resolution"`
	Participants string    `db:"participants"` // JSON array
	RecordedBy   string    `db:"recorded_by"`
	CreatedAt    time.Time `db:"created_at"`
}

// GovernanceVote represents a tallied governance vote.
type GovernanceVote struct {
	ID        int64     `db:"id"`
	ProposalID string   `db:"proposal_id"`
	AgentRef  string    `db:"agent_ref"`
	Vote      string    `db:"vote"` // approve, reject, abstain
	Reason    string    `db:"reason"`
	CreatedAt time.Time `db:"created_at"`
}

// GovernanceProposal represents a governance change proposal.
type GovernanceProposal struct {
	ID          int64     `db:"id"`
	Topic       string    `db:"topic"`
	AgentRef    string    `db:"agent_ref"`
	Content     string    `db:"content"`
	Status      string    `db:"status"` // open, enacted, rejected
	ApproveCount int      `db:"approve_count"`
	RejectCount  int      `db:"reject_count"`
	CreatedAt   time.Time `db:"created_at"`
	EnactedAt   *time.Time `db:"enacted_at"`
}

// SpawnSlot represents the atomic spawn control state.
type SpawnSlot struct {
	ID          int64     `db:"id"`
	AgentName   string    `db:"agent_name"`
	AllocatedAt time.Time `db:"allocated_at"`
	ReleasedAt  *time.Time `db:"released_at"`
}

// PlanningState represents a generation's N+2 coordination plan.
type PlanningState struct {
	ID          int64     `db:"id"`
	Role        string    `db:"role"`
	AgentName   string    `db:"agent_name"`
	Generation  int       `db:"generation"`
	MyWork      string    `db:"my_work"`
	N1Priority  string    `db:"n1_priority"`
	N2Priority  string    `db:"n2_priority"`
	Blockers    string    `db:"blockers"`
	CreatedAt   time.Time `db:"created_at"`
}

// HealthStatus represents the coordinator's health check response.
type HealthStatus struct {
	Status     string `json:"status"`
	DBPing     bool   `json:"db_ping"`
	Generation int    `json:"generation"`
	Uptime     string `json:"uptime"`
}
