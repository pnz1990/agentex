// Package audit provides a durable audit trail for agentex coordinator and agent actions.
// Audit entries are written as JSON lines to a local buffer file and periodically
// flushed to S3 at s3://<bucket>/audit/YYYY-MM-DD.jsonl.
//
// Design: Option 3 from issue #2062 — write to /tmp/audit.jsonl, flush to S3 every N seconds.
// This handles pod crashes gracefully (lose at most one flush interval of entries).
// Uses aws-cli (already installed in the runner image) to append via download-append-upload.
package audit

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"time"
)

// Entry is a single audit log record.
type Entry struct {
	Timestamp   time.Time `json:"timestamp"`
	AgentName   string    `json:"agentName"`
	Role        string    `json:"role"`
	Action      string    `json:"action"`
	IssueNumber int       `json:"issueNumber,omitempty"`
	PRNumber    int       `json:"prNumber,omitempty"`
	Outcome     string    `json:"outcome"` // "success", "failure", "skipped"
	Details     string    `json:"details,omitempty"`
}

// ActionType constants for well-known coordinator/agent actions.
const (
	ActionDispatch     = "dispatch"      // coordinator dispatched a task to an agent
	ActionSpawn        = "spawn"         // coordinator spawned a new agent
	ActionKill         = "kill"          // coordinator killed a stuck agent
	ActionRelease      = "release"       // coordinator released an assignment
	ActionRequeue      = "requeue"       // coordinator re-queued a failed issue
	ActionRemediate    = "remediate"     // coordinator took a remediation action
	ActionHeartbeat    = "heartbeat"     // coordinator heartbeat (summary)
	ActionTaskStart    = "task_start"    // agent started a task
	ActionPRCreated    = "pr_created"    // agent created a pull request
	ActionReportPosted = "report_posted" // agent posted a Report CR
	ActionSuccessor    = "successor"     // agent spawned a successor
	ActionExit         = "exit"          // agent exited
)

// Logger buffers audit entries and periodically flushes them to S3.
type Logger struct {
	mu          sync.Mutex
	localPath   string        // local buffer file (e.g. /tmp/audit.jsonl)
	bucket      string        // S3 bucket name
	awsRegion   string        // AWS region
	flushEvery  time.Duration // how often to push to S3
	logger      *slog.Logger
	agentName   string
	role        string
	stopCh      chan struct{}
	flushDoneCh chan struct{}
}

// Config holds Logger configuration.
type Config struct {
	AgentName  string
	Role       string
	Bucket     string
	AwsRegion  string
	LocalPath  string        // defaults to /tmp/audit.jsonl
	FlushEvery time.Duration // defaults to 60s
}

// New creates a new audit Logger and starts the background flush goroutine.
// Call Stop() to flush remaining entries and stop the background goroutine.
func New(cfg Config, logger *slog.Logger) *Logger {
	if cfg.LocalPath == "" {
		cfg.LocalPath = "/tmp/audit.jsonl"
	}
	if cfg.FlushEvery == 0 {
		cfg.FlushEvery = 60 * time.Second
	}

	l := &Logger{
		localPath:   cfg.LocalPath,
		bucket:      cfg.Bucket,
		awsRegion:   cfg.AwsRegion,
		flushEvery:  cfg.FlushEvery,
		logger:      logger,
		agentName:   cfg.AgentName,
		role:        cfg.Role,
		stopCh:      make(chan struct{}),
		flushDoneCh: make(chan struct{}),
	}
	return l
}

// logInfo logs at Info level if the logger is configured.
func (l *Logger) logInfo(msg string, args ...any) {
	if l.logger != nil {
		l.logger.Info(msg, args...)
	}
}

// logError logs at Error level if the logger is configured.
func (l *Logger) logError(msg string, args ...any) {
	if l.logger != nil {
		l.logger.Error(msg, args...)
	}
}

// logWarn logs at Warn level if the logger is configured.
func (l *Logger) logWarn(msg string, args ...any) {
	if l.logger != nil {
		l.logger.Warn(msg, args...)
	}
}

// Start launches the background flush loop. It blocks until ctx is cancelled
// or Stop() is called. Typically run in a goroutine.
func (l *Logger) Start(ctx context.Context) {
	defer close(l.flushDoneCh)

	ticker := time.NewTicker(l.flushEvery)
	defer ticker.Stop()

	l.logInfo("audit logger starting",
		"localPath", l.localPath,
		"bucket", l.bucket,
		"flushEvery", l.flushEvery,
	)

	for {
		select {
		case <-ctx.Done():
			l.flush()
			return
		case <-l.stopCh:
			l.flush()
			return
		case <-ticker.C:
			l.flush()
		}
	}
}

// Stop flushes remaining entries, stops the flush loop, and waits for it to exit.
func (l *Logger) Stop() {
	close(l.stopCh)
	<-l.flushDoneCh
}

// Log writes an audit entry to the local buffer.
func (l *Logger) Log(action, outcome, details string, issueNumber, prNumber int) {
	entry := Entry{
		Timestamp:   time.Now().UTC(),
		AgentName:   l.agentName,
		Role:        l.role,
		Action:      action,
		IssueNumber: issueNumber,
		PRNumber:    prNumber,
		Outcome:     outcome,
		Details:     details,
	}
	l.write(entry)
}

// LogEntry writes a pre-built Entry to the local buffer.
func (l *Logger) LogEntry(entry Entry) {
	if entry.Timestamp.IsZero() {
		entry.Timestamp = time.Now().UTC()
	}
	if entry.AgentName == "" {
		entry.AgentName = l.agentName
	}
	if entry.Role == "" {
		entry.Role = l.role
	}
	l.write(entry)
}

// write appends a JSON-line to the local buffer file.
func (l *Logger) write(entry Entry) {
	data, err := json.Marshal(entry)
	if err != nil {
		l.logError("audit: failed to marshal entry", "error", err)
		return
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	f, err := os.OpenFile(l.localPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		l.logError("audit: failed to open local buffer", "error", err, "path", l.localPath)
		return
	}
	defer f.Close()

	if _, err := f.Write(append(data, '\n')); err != nil {
		l.logError("audit: failed to write entry", "error", err)
	}
}

// flush appends the local buffer contents to the S3 audit file for today.
// Uses aws-cli: download today's file (if exists), append local buffer, re-upload.
// The local buffer is cleared after a successful upload.
func (l *Logger) flush() {
	if l.bucket == "" {
		return // S3 not configured — local-only mode
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	// Check if there's anything to flush
	info, err := os.Stat(l.localPath)
	if err != nil || info.Size() == 0 {
		return
	}

	today := time.Now().UTC().Format("2006-01-02")
	s3Key := fmt.Sprintf("audit/%s.jsonl", today)
	s3URI := fmt.Sprintf("s3://%s/%s", l.bucket, s3Key)

	// Download existing file from S3 (may not exist — that's fine)
	tmpMerge := l.localPath + ".merge"
	_ = os.Remove(tmpMerge)

	downloadCmd := exec.Command("aws", "s3", "cp", s3URI, tmpMerge,
		"--region", l.awsRegion,
		"--quiet",
	)
	// Ignore download errors (file may not exist yet)
	_ = downloadCmd.Run()

	// Append local buffer to the merged file
	localData, err := os.ReadFile(l.localPath)
	if err != nil {
		l.logError("audit: failed to read local buffer for flush", "error", err)
		return
	}

	mergeF, err := os.OpenFile(tmpMerge, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		l.logError("audit: failed to open merge file", "error", err)
		return
	}
	if _, err := mergeF.Write(localData); err != nil {
		mergeF.Close()
		l.logError("audit: failed to write to merge file", "error", err)
		return
	}
	mergeF.Close()

	// Upload merged file back to S3
	uploadCmd := exec.Command("aws", "s3", "cp", tmpMerge, s3URI,
		"--region", l.awsRegion,
		"--quiet",
	)
	if err := uploadCmd.Run(); err != nil {
		l.logError("audit: failed to upload to S3",
			"s3URI", s3URI, "error", err,
		)
		return
	}

	// Clear local buffer after successful upload
	if err := os.WriteFile(l.localPath, nil, 0o644); err != nil {
		l.logError("audit: failed to clear local buffer after flush", "error", err)
	}
	_ = os.Remove(tmpMerge)

	l.logInfo("audit: flushed to S3", "s3URI", s3URI, "bytes", len(localData))
}

// Query reads and filters audit entries for the given date from S3.
// Returns all entries matching the provided filters.
func Query(ctx context.Context, bucket, awsRegion, date string, filters QueryFilters, logger *slog.Logger) ([]Entry, error) {
	if bucket == "" {
		return nil, fmt.Errorf("bucket is required")
	}

	s3URI := fmt.Sprintf("s3://%s/audit/%s.jsonl", bucket, date)
	tmpFile := fmt.Sprintf("/tmp/audit-query-%s.jsonl", date)
	defer os.Remove(tmpFile)

	downloadCmd := exec.CommandContext(ctx, "aws", "s3", "cp", s3URI, tmpFile,
		"--region", awsRegion,
		"--quiet",
	)
	if err := downloadCmd.Run(); err != nil {
		return nil, fmt.Errorf("downloading audit log %s: %w", s3URI, err)
	}

	data, err := os.ReadFile(tmpFile)
	if err != nil {
		return nil, fmt.Errorf("reading downloaded audit log: %w", err)
	}

	var results []Entry
	for _, line := range splitLines(data) {
		if len(line) == 0 {
			continue
		}
		var entry Entry
		if err := json.Unmarshal(line, &entry); err != nil {
			if logger != nil {
				logger.Warn("audit: skipping malformed entry", "line", string(line))
			}
			continue
		}
		if filters.Matches(entry) {
			results = append(results, entry)
		}
	}
	return results, nil
}

// QueryFilters defines optional filters for audit log queries.
type QueryFilters struct {
	AgentName   string // filter by agent name (empty = all)
	IssueNumber int    // filter by issue number (0 = all)
	Action      string // filter by action type (empty = all)
}

// Matches returns true if the entry passes all configured filters.
func (f QueryFilters) Matches(entry Entry) bool {
	if f.AgentName != "" && entry.AgentName != f.AgentName {
		return false
	}
	if f.IssueNumber != 0 && entry.IssueNumber != f.IssueNumber {
		return false
	}
	if f.Action != "" && entry.Action != f.Action {
		return false
	}
	return true
}

// splitLines splits byte slice into non-empty lines.
func splitLines(data []byte) [][]byte {
	var lines [][]byte
	start := 0
	for i, b := range data {
		if b == '\n' {
			line := data[start:i]
			if len(line) > 0 {
				lines = append(lines, line)
			}
			start = i + 1
		}
	}
	if start < len(data) {
		line := data[start:]
		if len(line) > 0 {
			lines = append(lines, line)
		}
	}
	return lines
}
