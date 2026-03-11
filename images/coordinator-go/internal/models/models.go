// Package models defines the data types for the agentex work ledger.
// These correspond directly to the SQLite tables in internal/db/db.go.
package models

// Task represents a single unit of work (GitHub issue) in the work ledger.
// Replaces coordinator-state.taskQueue and activeAssignments.
type Task struct {
	ID             int64   `json:"id"`
	IssueNumber    int     `json:"issue_number"`
	Title          string  `json:"title,omitempty"`
	Labels         string  `json:"labels,omitempty"`         // JSON array
	Effort         string  `json:"effort,omitempty"`
	DependsOn      string  `json:"depends_on,omitempty"`     // JSON array
	State          string  `json:"state"`
	Priority       int     `json:"priority"`
	Source         string  `json:"source"`
	ClaimedBy      string  `json:"claimed_by,omitempty"`
	ClaimedAt      string  `json:"claimed_at,omitempty"`
	ClaimExpiresAt string  `json:"claim_expires_at,omitempty"`
	PRNumber       int     `json:"pr_number,omitempty"`
	PRURL          string  `json:"pr_url,omitempty"`
	MergedAt       string  `json:"merged_at,omitempty"`
	CompletedAt    string  `json:"completed_at,omitempty"`
	VisionQueue    bool    `json:"vision_queue"`
	CreatedAt      string  `json:"created_at"`
	UpdatedAt      string  `json:"updated_at"`
}

// Agent represents a single agent's persistent identity and stats.
// Replaces coordinator-state.activeAgents and S3 identity files.
type Agent struct {
	Name                      string  `json:"name"`
	DisplayName               string  `json:"display_name,omitempty"`
	Role                      string  `json:"role"`
	Generation                int     `json:"generation"`
	Specialization            string  `json:"specialization,omitempty"`
	SpecializationLabelCounts string  `json:"specialization_label_counts,omitempty"` // JSON object
	Status                    string  `json:"status"`
	TasksCompleted            int     `json:"tasks_completed"`
	IssuesFiled               int     `json:"issues_filed"`
	PRsMerged                 int     `json:"prs_merged"`
	ThoughtsPosted            int     `json:"thoughts_posted"`
	DebateQualityScore        int     `json:"debate_quality_score"`
	SynthesisCount            int     `json:"synthesis_count"`
	CitedSynthesesCount       int     `json:"cited_syntheses_count"`
	ReputationAverage         float64 `json:"reputation_average,omitempty"`
	LastSeenAt                string  `json:"last_seen_at,omitempty"`
	CreatedAt                 string  `json:"created_at"`
	UpdatedAt                 string  `json:"updated_at"`
}

// AgentActivity is an immutable record of a single agent action.
// Replaces Thought CRs (partial), Report CRs (partial), and S3 identity stats.
type AgentActivity struct {
	ID          int64  `json:"id"`
	AgentName   string `json:"agent_name"`
	DisplayName string `json:"display_name,omitempty"`
	Role        string `json:"role"`
	Generation  int    `json:"generation,omitempty"`
	ActionType  string `json:"action_type"`
	IssueNumber int    `json:"issue_number,omitempty"`
	PRNumber    int    `json:"pr_number,omitempty"`
	TargetAgent string `json:"target_agent,omitempty"`
	Details     string `json:"details,omitempty"` // JSON blob
	VisionScore int    `json:"vision_score,omitempty"`
	CreatedAt   string `json:"created_at"`
}

// Proposal represents a governance proposal.
// Replaces coordinator-state.voteRegistry and enactedDecisions.
type Proposal struct {
	ID            int64  `json:"id"`
	Topic         string `json:"topic"`
	Key           string `json:"key,omitempty"`
	Value         string `json:"value,omitempty"`
	Description   string `json:"description,omitempty"`
	ProposedBy    string `json:"proposed_by"`
	State         string `json:"state"`
	VoteApprove   int    `json:"vote_approve"`
	VoteReject    int    `json:"vote_reject"`
	VoteAbstain   int    `json:"vote_abstain"`
	Threshold     int    `json:"threshold"`
	EnactedAt     string `json:"enacted_at,omitempty"`
	EnactedValue  string `json:"enacted_value,omitempty"`
	ThoughtCRName string `json:"thought_cr_name,omitempty"`
	CreatedAt     string `json:"created_at"`
	UpdatedAt     string `json:"updated_at"`
}

// Vote represents a single agent's vote on a proposal.
type Vote struct {
	ID            int64  `json:"id"`
	ProposalID    int64  `json:"proposal_id"`
	Voter         string `json:"voter"`
	Stance        string `json:"stance"`
	Reason        string `json:"reason,omitempty"`
	ThoughtCRName string `json:"thought_cr_name,omitempty"`
	VotedAt       string `json:"voted_at"`
}

// Debate represents a single message in a debate thread.
// Replaces S3 debates/*.json, unresolvedDebates, and debateStats.
type Debate struct {
	ID             int64  `json:"id"`
	ThreadID       string `json:"thread_id"`
	ThoughtCRName  string `json:"thought_cr_name,omitempty"`
	ParentID       *int64 `json:"parent_id,omitempty"`
	AgentName      string `json:"agent_name"`
	DisplayName    string `json:"display_name,omitempty"`
	Stance         string `json:"stance,omitempty"`
	Content        string `json:"content"`
	Confidence     int    `json:"confidence,omitempty"`
	Topic          string `json:"topic,omitempty"`
	Component      string `json:"component,omitempty"`
	IsResolved     bool   `json:"is_resolved"`
	Resolution     string `json:"resolution,omitempty"`
	ResolvedBy     string `json:"resolved_by,omitempty"`
	ResolvedAt     string `json:"resolved_at,omitempty"`
	CreatedAt      string `json:"created_at"`
}

// Metric is a single time-series data point.
// Replaces debateStats strings, specializedAssignments, and similar counters.
type Metric struct {
	ID         int64  `json:"id"`
	Metric     string `json:"metric"`
	Value      int64  `json:"value"`
	Agent      string `json:"agent,omitempty"`
	Labels     string `json:"labels,omitempty"` // JSON object
	RecordedAt string `json:"recorded_at"`
}

// VisionQueueItem is a civilization-voted goal that takes priority over the
// normal GitHub task queue.  Replaces coordinator-state.visionQueue.
type VisionQueueItem struct {
	ID          int64  `json:"id"`
	FeatureName string `json:"feature_name"`
	Description string `json:"description,omitempty"`
	IssueNumber int    `json:"issue_number,omitempty"`
	ProposedBy  string `json:"proposed_by"`
	VoteCount   int    `json:"vote_count"`
	State       string `json:"state"`
	ClaimedBy   string `json:"claimed_by,omitempty"`
	ClaimedAt   string `json:"claimed_at,omitempty"`
	EnactedAt   string `json:"enacted_at"`
	UpdatedAt   string `json:"updated_at"`
}

// ConstitutionLogEntry records a change to a constitution constant.
// Replaces enactedDecisions.
type ConstitutionLogEntry struct {
	ID        int64  `json:"id"`
	Key       string `json:"key"`
	OldValue  string `json:"old_value,omitempty"`
	NewValue  string `json:"new_value"`
	Reason    string `json:"reason,omitempty"`
	EnactedBy string `json:"enacted_by"`
	VoteCount int    `json:"vote_count"`
	EnactedAt string `json:"enacted_at"`
}

// DebateStats is the structured replacement for the debateStats ConfigMap string.
type DebateStats struct {
	TotalResponses  int `json:"total_responses"`
	TotalThreads    int `json:"total_threads"`
	DisagreeCount   int `json:"disagree_count"`
	SynthesizeCount int `json:"synthesize_count"`
	UnresolvedCount int `json:"unresolved_count"`
}

// ClaimTaskRequest is the JSON body for POST /api/tasks/claim.
type ClaimTaskRequest struct {
	AgentName   string `json:"agent_name" binding:"required"`
	IssueNumber int    `json:"issue_number" binding:"required"`
}

// ClaimTaskResponse is the JSON response for a successful task claim.
type ClaimTaskResponse struct {
	Task           *Task  `json:"task"`
	ClaimExpiresAt string `json:"claim_expires_at"`
}

// PostDebateRequest is the JSON body for POST /api/debates.
type PostDebateRequest struct {
	ThreadID      string `json:"thread_id,omitempty"`
	ParentCRName  string `json:"parent_cr_name,omitempty"`
	AgentName     string `json:"agent_name"  binding:"required"`
	DisplayName   string `json:"display_name,omitempty"`
	Stance        string `json:"stance"       binding:"required"`
	Content       string `json:"content"      binding:"required"`
	Confidence    int    `json:"confidence"`
	Topic         string `json:"topic,omitempty"`
	Component     string `json:"component,omitempty"`
	ThoughtCRName string `json:"thought_cr_name,omitempty"`
}

// CastVoteRequest is the JSON body for POST /api/proposals/:id/vote.
type CastVoteRequest struct {
	Voter         string `json:"voter"   binding:"required"`
	Stance        string `json:"stance"  binding:"required"`
	Reason        string `json:"reason,omitempty"`
	ThoughtCRName string `json:"thought_cr_name,omitempty"`
}

// ErrorResponse is the standard JSON error envelope.
type ErrorResponse struct {
	Error string `json:"error"`
}
