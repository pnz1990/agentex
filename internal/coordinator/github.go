package coordinator

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/pnz1990/agentex/internal/audit"
)

// GitHubIssueFetcher abstracts the GitHub API call to fetch open issues.
// Using an interface makes it easy to swap in a fake for tests.
type GitHubIssueFetcher interface {
	// FetchOpenIssues returns open, unassigned issues for the given repo
	// (format "owner/repo"). It returns at most maxIssues, sorted by
	// updated-at descending (GitHub default).
	FetchOpenIssues(ctx context.Context, repo string, maxIssues int) ([]GitHubIssue, error)
}

// GitHubIssue is a minimal representation of a GitHub issue.
type GitHubIssue struct {
	Number int
	Title  string
	Labels []string
	// HasOpenPR is true when the issue has an associated open pull request
	// (detected by searching for "Closes #<number>" in open PRs).
	// This field is NOT populated by FetchOpenIssues — it is used by the
	// coordinator dispatch logic.
	HasOpenPR bool
}

// httpGitHubFetcher calls the GitHub REST API using net/http and the
// GITHUB_TOKEN environment variable for authentication.
type httpGitHubFetcher struct {
	httpClient *http.Client
	logger     *slog.Logger
}

// newHTTPGitHubFetcher creates a fetcher that calls the GitHub REST API.
func newHTTPGitHubFetcher(logger *slog.Logger) *httpGitHubFetcher {
	return &httpGitHubFetcher{
		httpClient: &http.Client{Timeout: 15 * time.Second},
		logger:     logger,
	}
}

// githubIssueJSON is the minimal subset of the GitHub issues API response.
type githubIssueJSON struct {
	Number      int    `json:"number"`
	Title       string `json:"title"`
	PullRequest *struct {
		URL string `json:"url"`
	} `json:"pull_request,omitempty"`
	Labels []struct {
		Name string `json:"name"`
	} `json:"labels"`
}

// FetchOpenIssues calls GET /repos/{owner}/{repo}/issues?state=open&per_page=N
// and returns issues that are not pull requests.
func (f *httpGitHubFetcher) FetchOpenIssues(ctx context.Context, repo string, maxIssues int) ([]GitHubIssue, error) {
	if repo == "" {
		return nil, fmt.Errorf("github repo is not configured")
	}

	token := os.Getenv("GITHUB_TOKEN")
	if token == "" {
		token = os.Getenv("GH_TOKEN")
	}

	perPage := maxIssues
	if perPage > 100 {
		perPage = 100 // GitHub API max per_page
	}

	url := fmt.Sprintf(
		"https://api.github.com/repos/%s/issues?state=open&per_page=%d&sort=updated&direction=desc",
		repo, perPage,
	)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("building github request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := f.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("github api call: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("github api returned %d for %s", resp.StatusCode, url)
	}

	var raw []githubIssueJSON
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, fmt.Errorf("decoding github response: %w", err)
	}

	var issues []GitHubIssue
	for _, r := range raw {
		// GitHub returns PRs in the issues endpoint — skip them.
		if r.PullRequest != nil {
			continue
		}
		issue := GitHubIssue{
			Number: r.Number,
			Title:  r.Title,
		}
		for _, lbl := range r.Labels {
			issue.Labels = append(issue.Labels, lbl.Name)
		}
		issues = append(issues, issue)
	}

	return issues, nil
}

// refreshTaskQueue fetches open GitHub issues, scores them by vision priority,
// filters out already-assigned issues, and writes the sorted queue back to the
// coordinator-state ConfigMap. Implements issue #2056.
func (c *Coordinator) refreshTaskQueue(ctx context.Context) error {
	constitution := c.config.GetConstitution()
	if constitution.GithubRepo == "" {
		c.logger.Warn("task queue refresh skipped: githubRepo not set in constitution")
		return nil
	}

	c.logger.Info("refreshing task queue from GitHub", "repo", constitution.GithubRepo)

	issues, err := c.githubFetcher.FetchOpenIssues(ctx, constitution.GithubRepo, 100)
	if err != nil {
		return fmt.Errorf("fetching open issues: %w", err)
	}

	c.logger.Info("fetched open issues from GitHub",
		"count", len(issues),
		"repo", constitution.GithubRepo,
	)

	// Build label cache for scoring
	labelCache := make(map[int][]string, len(issues))
	for _, issue := range issues {
		labelCache[issue.Number] = issue.Labels
	}

	// Extract issue numbers
	numbers := make([]int, 0, len(issues))
	for _, issue := range issues {
		numbers = append(numbers, issue.Number)
	}

	// Load current state to merge with vision queue and filter assignments
	state, err := c.stateManager.Load(ctx)
	if err != nil {
		return fmt.Errorf("loading state for queue refresh: %w", err)
	}

	// Filter issues that are already actively assigned
	openPRs := map[int]bool{} // populated by PR scan if needed; empty for now
	available := FilterBlockedIssues(numbers, state.ActiveAssignments, openPRs)

	// Score and sort
	sorted := SortQueue(available, labelCache)

	// Merge with vision queue (vision items come first)
	merged := MergeQueues(state.VisionQueue, sorted)

	// Write back to ConfigMap
	if err := c.stateManager.UpdateField(ctx, "taskQueue", formatIntList(merged)); err != nil {
		return fmt.Errorf("writing task queue: %w", err)
	}

	// Update metrics (#2058)
	if c.metrics != nil {
		c.metrics.TaskQueueSize.Set(float64(len(merged)))
	}

	c.logger.Info("task queue updated",
		"size", len(merged),
		"visionItems", len(state.VisionQueue),
	)

	return nil
}

// issueNumberName builds a deterministic Kubernetes-safe name for a task/agent
// based on the issue number and a short suffix derived from the issue number.
func issueNumberName(issueNumber int, prefix string) string {
	// Format: "<prefix>-issue-<N>" — stays under 63 chars for K8s name limits.
	name := fmt.Sprintf("%s-issue-%d", prefix, issueNumber)
	// Sanitize to Kubernetes DNS subdomain rules: lowercase alphanumeric + hyphens.
	name = strings.ToLower(name)
	// Trim to 63 chars if somehow too long (e.g. very large issue numbers)
	if len(name) > 63 {
		name = name[:63]
	}
	return name
}

// dispatchNextTask picks the highest-priority unblocked task from the queue
// and spawns an agent for it. It is called every tick so that as soon as a
// spawn slot opens up (after an agent finishes), work starts immediately.
// Implements issue #2057.
func (c *Coordinator) dispatchNextTask(ctx context.Context) error {
	// Check kill switch first — never dispatch when kill switch is active.
	active, reason, err := c.IsKillSwitchActive(ctx)
	if err != nil {
		return fmt.Errorf("checking kill switch before dispatch: %w", err)
	}
	if active {
		c.logger.Debug("dispatch skipped: kill switch active", "reason", reason)
		if c.metrics != nil {
			c.metrics.SpawnBlocked.Inc()
		}
		return nil
	}

	// Load current state
	state, err := c.stateManager.Load(ctx)
	if err != nil {
		return fmt.Errorf("loading state for dispatch: %w", err)
	}

	// Check spawn slots
	if state.SpawnSlots <= 0 {
		c.logger.Debug("dispatch skipped: no spawn slots available", "spawnSlots", state.SpawnSlots)
		return nil
	}

	// Merge vision queue + task queue and filter blocked issues
	openPRs := map[int]bool{}
	allIssues := MergeQueues(state.VisionQueue, state.TaskQueue)
	available := FilterBlockedIssues(allIssues, state.ActiveAssignments, openPRs)

	if len(available) == 0 {
		c.logger.Debug("dispatch skipped: no available tasks in queue",
			"queueSize", len(allIssues),
			"activeAssignments", len(state.ActiveAssignments),
		)
		return nil
	}

	// Pick the next issue
	issueNumber := available[0]

	// Generate task and agent names
	epoch := strconv.FormatInt(time.Now().Unix(), 36) // short base-36 timestamp for uniqueness
	taskName := issueNumberName(issueNumber, "task")
	agentName := fmt.Sprintf("worker-%s-%s", strconv.Itoa(issueNumber), epoch)
	if len(agentName) > 63 {
		agentName = agentName[:63]
	}

	c.logger.Info("dispatching task to new agent",
		"issue", issueNumber,
		"task", taskName,
		"agent", agentName,
	)

	if err := c.SpawnAgent(ctx, "worker", issueNumber, agentName); err != nil {
		// If there was an error because task CR already exists for this issue,
		// that's expected — just log and continue.
		if strings.Contains(err.Error(), "already exists") {
			c.logger.Debug("task already exists, skipping dispatch", "issue", issueNumber)
			return nil
		}
		return fmt.Errorf("spawning agent for issue %d: %w", issueNumber, err)
	}

	c.logger.Info("agent dispatched successfully",
		"agent", agentName,
		"issue", issueNumber,
	)

	// Audit: record dispatch decision (#2062)
	if c.auditLog != nil {
		c.auditLog.Log(
			audit.ActionDispatch,
			"success",
			fmt.Sprintf("agent=%s task=%s", agentName, taskName),
			issueNumber,
			0,
		)
	}

	// Update metrics (#2058)
	if c.metrics != nil {
		c.metrics.AgentsSpawned.Inc()
		c.metrics.TasksClaimed.Inc()
	}

	return nil
}
