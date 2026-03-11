// Command migrate imports coordinator-state ConfigMap data into the SQLite
// work ledger database. Run this once when deploying the Go coordinator
// alongside (or replacing) the existing bash coordinator.
//
// # What It Migrates
//
// From coordinator-state ConfigMap:
//   - taskQueue         → tasks table (state='queued')
//   - activeAssignments → tasks table (state='claimed', claimed_by set)
//   - activeAgents      → agents table (status='active')
//   - visionQueue       → vision_queue table
//   - enactedDecisions  → constitution_log table
//   - debateStats       → metrics table (aggregate counters)
//
// From agentex-constitution ConfigMap:
//   - circuitBreakerLimit → constitution_log (key='circuitBreakerLimit')
//
// # Usage
//
//	migrate [--db /data/coordinator.db] [--namespace agentex] [--dry-run]
//
// The tool is safe to re-run: all inserts use INSERT OR IGNORE so existing
// rows are not overwritten.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"

	"github.com/pnz1990/agentex/coordinator/internal/db"
)

func main() {
	dbPath := flag.String("db", envOrDefault("COORDINATOR_DB", "/data/coordinator.db"),
		"Path to the SQLite database file")
	ns := flag.String("namespace", envOrDefault("NAMESPACE", "agentex"),
		"Kubernetes namespace containing coordinator-state ConfigMap")
	dryRun := flag.Bool("dry-run", false,
		"Print what would be migrated without writing to the database")
	flag.Parse()

	log.SetFlags(log.Ldate | log.Ltime | log.LUTC | log.Lshortfile)
	log.Printf("[migrate] starting (db=%s namespace=%s dry-run=%v)", *dbPath, *ns, *dryRun)

	// ── Read ConfigMaps via kubectl ────────────────────────────────────────
	log.Printf("[migrate] reading coordinator-state ConfigMap...")
	stateData, err := kubectlGetConfigMapData("coordinator-state", *ns)
	if err != nil {
		log.Fatalf("[migrate] fatal: read coordinator-state: %v", err)
	}

	log.Printf("[migrate] reading agentex-constitution ConfigMap...")
	constitutionData, err := kubectlGetConfigMapData("agentex-constitution", *ns)
	if err != nil {
		// Not fatal — constitution may not be present in all environments
		log.Printf("[migrate] warn: read agentex-constitution: %v (skipping)", err)
		constitutionData = map[string]string{}
	}

	// ── Summarise what we found ────────────────────────────────────────────
	plan := buildMigrationPlan(stateData, constitutionData)
	log.Printf("[migrate] migration plan:")
	for _, line := range plan.Summary() {
		log.Printf("  %s", line)
	}

	if *dryRun {
		log.Printf("[migrate] dry-run mode: exiting without writing")
		os.Exit(0)
	}

	// ── Open / initialise the database ────────────────────────────────────
	if dir := filepath.Dir(*dbPath); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			log.Fatalf("[migrate] fatal: create db dir: %v", err)
		}
	}
	database, err := db.Open(*dbPath)
	if err != nil {
		log.Fatalf("[migrate] fatal: open db: %v", err)
	}
	defer func() { _ = database.Close() }()

	// ── Execute migration ─────────────────────────────────────────────────
	ctx := context.Background()
	stats, err := applyMigration(ctx, database.DB, plan)
	if err != nil {
		log.Fatalf("[migrate] fatal: apply migration: %v", err)
	}

	log.Printf("[migrate] done: tasks=%d agents=%d vision=%d constitution=%d metrics=%d",
		stats.Tasks, stats.Agents, stats.VisionQueue, stats.Constitution, stats.Metrics)
}

// ── ConfigMap reading ─────────────────────────────────────────────────────────

// kubectlGetConfigMapData shells out to kubectl to fetch a ConfigMap's .data
// as a Go map[string]string.  This avoids adding a Kubernetes client library
// dependency to the migration binary.
func kubectlGetConfigMapData(name, namespace string) (map[string]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx,
		"kubectl", "get", "configmap", name,
		"-n", namespace,
		"-o", "jsonpath={.data}",
	).Output()
	if err != nil {
		return nil, fmt.Errorf("kubectl get configmap %s: %w", name, err)
	}

	var data map[string]string
	if err := json.Unmarshal(out, &data); err != nil {
		return nil, fmt.Errorf("parse configmap %s data: %w", name, err)
	}
	return data, nil
}

// ── Migration plan ────────────────────────────────────────────────────────────

// migrationPlan holds all parsed data ready to insert into SQLite.
type migrationPlan struct {
	Tasks        []taskRow
	Agents       []agentRow
	VisionQueue  []visionQueueRow
	Constitution []constitutionRow
	Metrics      []metricRow
}

type taskRow struct {
	IssueNumber int
	State       string // 'queued' or 'claimed'
	ClaimedBy   string
	ClaimedAt   string
	Source      string
	Priority    int
}

type agentRow struct {
	Name   string
	Role   string
	Status string
}

type visionQueueRow struct {
	FeatureName string
	Description string
	IssueNumber int
	ProposedBy  string
	VoteCount   int
	State       string
}

type constitutionRow struct {
	Key      string
	NewValue string
	Reason   string
	EnactedBy string
}

type metricRow struct {
	Metric string
	Value  int
}

// Summary returns human-readable lines describing what will be migrated.
func (p *migrationPlan) Summary() []string {
	return []string{
		fmt.Sprintf("tasks to import:        %d (queued) + %d (claimed)",
			countState(p.Tasks, "queued"), countState(p.Tasks, "claimed")),
		fmt.Sprintf("agents to import:       %d active", len(p.Agents)),
		fmt.Sprintf("vision queue entries:   %d", len(p.VisionQueue)),
		fmt.Sprintf("constitution log rows:  %d", len(p.Constitution)),
		fmt.Sprintf("metric counters:        %d", len(p.Metrics)),
	}
}

func countState(tasks []taskRow, state string) int {
	n := 0
	for _, t := range tasks {
		if t.State == state {
			n++
		}
	}
	return n
}

// buildMigrationPlan parses the raw ConfigMap string fields into typed rows.
func buildMigrationPlan(state, constitution map[string]string) *migrationPlan {
	plan := &migrationPlan{}

	// ── taskQueue: "1782,1783" ──────────────────────────────────────────
	if q := strings.TrimSpace(state["taskQueue"]); q != "" {
		for _, raw := range strings.Split(q, ",") {
			raw = strings.TrimSpace(raw)
			if raw == "" {
				continue
			}
			n, err := strconv.Atoi(raw)
			if err != nil || n <= 0 {
				continue
			}
			plan.Tasks = append(plan.Tasks, taskRow{
				IssueNumber: n,
				State:       "queued",
				Source:      "github",
				Priority:    5,
			})
		}
	}

	// ── activeAssignments: "worker-123:676,worker-456:789" ──────────────
	alreadyQueued := map[int]bool{}
	for _, t := range plan.Tasks {
		alreadyQueued[t.IssueNumber] = true
	}

	now := time.Now().UTC().Format(time.RFC3339)
	if aa := strings.TrimSpace(state["activeAssignments"]); aa != "" {
		for _, pair := range strings.Split(aa, ",") {
			pair = strings.TrimSpace(pair)
			parts := strings.SplitN(pair, ":", 2)
			if len(parts) != 2 {
				continue
			}
			agentName := strings.TrimSpace(parts[0])
			issueStr := strings.TrimSpace(parts[1])
			n, err := strconv.Atoi(issueStr)
			if err != nil || n <= 0 {
				continue
			}
			if alreadyQueued[n] {
				// Update in place instead of adding a duplicate
				for i := range plan.Tasks {
					if plan.Tasks[i].IssueNumber == n {
						plan.Tasks[i].State = "claimed"
						plan.Tasks[i].ClaimedBy = agentName
						plan.Tasks[i].ClaimedAt = now
					}
				}
				continue
			}
			plan.Tasks = append(plan.Tasks, taskRow{
				IssueNumber: n,
				State:       "claimed",
				ClaimedBy:   agentName,
				ClaimedAt:   now,
				Source:      "github",
				Priority:    5,
			})
			alreadyQueued[n] = true
		}
	}

	// ── activeAgents: "worker-abc:worker,planner-xyz:planner" ───────────
	if aa := strings.TrimSpace(state["activeAgents"]); aa != "" {
		for _, pair := range strings.Split(aa, ",") {
			pair = strings.TrimSpace(pair)
			parts := strings.SplitN(pair, ":", 2)
			if len(parts) != 2 {
				continue
			}
			name := strings.TrimSpace(parts[0])
			role := strings.TrimSpace(parts[1])
			if name == "" || role == "" {
				continue
			}
			plan.Agents = append(plan.Agents, agentRow{
				Name:   name,
				Role:   normalizeRole(role),
				Status: "active",
			})
		}
	}

	// ── visionQueue: "feature:description:ts:proposer;feature2:..." ─────
	if vq := strings.TrimSpace(state["visionQueue"]); vq != "" {
		for _, entry := range strings.Split(vq, ";") {
			entry = strings.TrimSpace(entry)
			if entry == "" {
				continue
			}
			parts := strings.SplitN(entry, ":", 4)
			row := visionQueueRow{State: "active", ProposedBy: "coordinator"}
			switch len(parts) {
			case 1:
				// Might be a plain issue number
				if n, err := strconv.Atoi(parts[0]); err == nil {
					row.FeatureName = fmt.Sprintf("issue-%d", n)
					row.IssueNumber = n
				} else {
					row.FeatureName = parts[0]
				}
			case 2:
				row.FeatureName = parts[0]
				row.Description = parts[1]
			case 3:
				row.FeatureName = parts[0]
				row.Description = parts[1]
				// parts[2] is timestamp — ignore for import
			case 4:
				row.FeatureName = parts[0]
				row.Description = parts[1]
				// parts[2] is timestamp
				row.ProposedBy = parts[3]
			}
			if row.FeatureName == "" {
				continue
			}
			plan.VisionQueue = append(plan.VisionQueue, row)
		}
	}

	// ── enactedDecisions: "key=val|ts|votes|key2=val2|..." ─────────────
	// Format observed in coordinator-state: "circuitBreakerLimit=6|2026-03-09|4-votes"
	if ed := strings.TrimSpace(state["enactedDecisions"]); ed != "" {
		for _, entry := range strings.Split(ed, "|") {
			entry = strings.TrimSpace(entry)
			if entry == "" {
				continue
			}
			// Skip pure timestamp or vote-count tokens
			if strings.Contains(entry, "T") && strings.Contains(entry, ":") {
				continue // looks like a timestamp
			}
			if strings.HasSuffix(entry, "-votes") {
				continue
			}
			if idx := strings.Index(entry, "="); idx > 0 {
				key := entry[:idx]
				val := entry[idx+1:]
				plan.Constitution = append(plan.Constitution, constitutionRow{
					Key:       key,
					NewValue:  val,
					Reason:    "imported from enactedDecisions ConfigMap field",
					EnactedBy: "migration",
				})
			}
		}
	}

	// Also import circuitBreakerLimit from constitution ConfigMap
	if cb := strings.TrimSpace(constitution["circuitBreakerLimit"]); cb != "" {
		plan.Constitution = append(plan.Constitution, constitutionRow{
			Key:       "circuitBreakerLimit",
			NewValue:  cb,
			Reason:    "imported from agentex-constitution ConfigMap",
			EnactedBy: "migration",
		})
	}

	// ── debateStats: "responses=738 threads=666 disagree=184 synthesize=202" ──
	if ds := strings.TrimSpace(state["debateStats"]); ds != "" {
		for _, kv := range strings.Fields(ds) {
			parts := strings.SplitN(kv, "=", 2)
			if len(parts) != 2 {
				continue
			}
			key := strings.TrimSpace(parts[0])
			valStr := strings.TrimSpace(parts[1])
			val, err := strconv.Atoi(valStr)
			if err != nil {
				continue
			}
			metricName := "debate_" + key
			plan.Metrics = append(plan.Metrics, metricRow{
				Metric: metricName,
				Value:  val,
			})
		}
	}

	// ── specializedAssignments / genericAssignments counters ────────────
	for _, field := range []string{"specializedAssignments", "genericAssignments"} {
		if v := strings.TrimSpace(state[field]); v != "" {
			if n, err := strconv.Atoi(v); err == nil {
				plan.Metrics = append(plan.Metrics, metricRow{
					Metric: camelToSnake(field),
					Value:  n,
				})
			}
		}
	}

	return plan
}

// normalizeRole maps legacy / alternate role names to the canonical set used
// in the agents table CHECK constraint.
func normalizeRole(r string) string {
	switch strings.ToLower(r) {
	case "planner":
		return "planner"
	case "worker":
		return "worker"
	case "reviewer":
		return "reviewer"
	case "architect":
		return "architect"
	case "god-delegate", "god_delegate", "goddelegate":
		return "god-delegate"
	case "seed":
		return "seed"
	case "coordinator":
		return "coordinator"
	case "critic":
		return "critic"
	default:
		return "worker" // safe fallback
	}
}

// camelToSnake converts camelCase to snake_case for metric names.
func camelToSnake(s string) string {
	var out []rune
	for i, r := range s {
		if r >= 'A' && r <= 'Z' {
			if i > 0 {
				out = append(out, '_')
			}
			out = append(out, r+32)
		} else {
			out = append(out, r)
		}
	}
	return string(out)
}

// ── Apply migration ───────────────────────────────────────────────────────────

type migrationStats struct {
	Tasks        int
	Agents       int
	VisionQueue  int
	Constitution int
	Metrics      int
}

// applyMigration inserts all rows from plan into the database inside a single
// transaction for atomicity. Uses INSERT OR IGNORE to avoid overwriting
// existing rows if the migration is re-run.
func applyMigration(ctx context.Context, sqlDB *sql.DB, plan *migrationPlan) (migrationStats, error) {
	tx, err := sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return migrationStats{}, fmt.Errorf("begin transaction: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	stats := migrationStats{}

	// ── tasks ─────────────────────────────────────────────────────────────
	stmtTask, err := tx.PrepareContext(ctx, `
		INSERT OR IGNORE INTO tasks
			(issue_number, state, claimed_by, claimed_at, source, priority, created_at, updated_at)
		VALUES (?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?,
		        strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		        strftime('%Y-%m-%dT%H:%M:%SZ','now'))
	`)
	if err != nil {
		return stats, fmt.Errorf("prepare task stmt: %w", err)
	}
	defer stmtTask.Close()

	for _, t := range plan.Tasks {
		res, err := stmtTask.ExecContext(ctx, t.IssueNumber, t.State, t.ClaimedBy, t.ClaimedAt, t.Source, t.Priority)
		if err != nil {
			log.Printf("[migrate] warn: insert task #%d: %v", t.IssueNumber, err)
			continue
		}
		if n, _ := res.RowsAffected(); n > 0 {
			stats.Tasks++
		}
	}

	// ── agents ────────────────────────────────────────────────────────────
	stmtAgent, err := tx.PrepareContext(ctx, `
		INSERT OR IGNORE INTO agents (name, role, status, created_at, updated_at)
		VALUES (?, ?, ?,
		        strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		        strftime('%Y-%m-%dT%H:%M:%SZ','now'))
	`)
	if err != nil {
		return stats, fmt.Errorf("prepare agent stmt: %w", err)
	}
	defer stmtAgent.Close()

	for _, a := range plan.Agents {
		res, err := stmtAgent.ExecContext(ctx, a.Name, a.Role, a.Status)
		if err != nil {
			log.Printf("[migrate] warn: insert agent %s: %v", a.Name, err)
			continue
		}
		if n, _ := res.RowsAffected(); n > 0 {
			stats.Agents++
		}
	}

	// ── vision_queue ──────────────────────────────────────────────────────
	stmtVQ, err := tx.PrepareContext(ctx, `
		INSERT OR IGNORE INTO vision_queue
			(feature_name, description, issue_number, proposed_by, vote_count, state,
			 enacted_at, updated_at)
		VALUES (?, ?, NULLIF(?, 0), ?, ?, ?,
		        strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		        strftime('%Y-%m-%dT%H:%M:%SZ','now'))
	`)
	if err != nil {
		return stats, fmt.Errorf("prepare vision_queue stmt: %w", err)
	}
	defer stmtVQ.Close()

	for _, v := range plan.VisionQueue {
		res, err := stmtVQ.ExecContext(ctx, v.FeatureName, v.Description, v.IssueNumber,
			v.ProposedBy, v.VoteCount, v.State)
		if err != nil {
			log.Printf("[migrate] warn: insert vision entry %q: %v", v.FeatureName, err)
			continue
		}
		if n, _ := res.RowsAffected(); n > 0 {
			stats.VisionQueue++
		}
	}

	// ── constitution_log ─────────────────────────────────────────────────
	stmtConst, err := tx.PrepareContext(ctx, `
		INSERT INTO constitution_log (key, new_value, reason, enacted_by, vote_count, enacted_at)
		VALUES (?, ?, ?, ?, 0, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
	`)
	if err != nil {
		return stats, fmt.Errorf("prepare constitution_log stmt: %w", err)
	}
	defer stmtConst.Close()

	for _, c := range plan.Constitution {
		res, err := stmtConst.ExecContext(ctx, c.Key, c.NewValue, c.Reason, c.EnactedBy)
		if err != nil {
			log.Printf("[migrate] warn: insert constitution row key=%s: %v", c.Key, err)
			continue
		}
		if n, _ := res.RowsAffected(); n > 0 {
			stats.Constitution++
		}
	}

	// ── metrics ──────────────────────────────────────────────────────────
	stmtMetric, err := tx.PrepareContext(ctx, `
		INSERT INTO metrics (metric, value, recorded_at)
		VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
	`)
	if err != nil {
		return stats, fmt.Errorf("prepare metric stmt: %w", err)
	}
	defer stmtMetric.Close()

	for _, m := range plan.Metrics {
		res, err := stmtMetric.ExecContext(ctx, m.Metric, m.Value)
		if err != nil {
			log.Printf("[migrate] warn: insert metric %s: %v", m.Metric, err)
			continue
		}
		if n, _ := res.RowsAffected(); n > 0 {
			stats.Metrics++
		}
	}

	if err = tx.Commit(); err != nil {
		return migrationStats{}, fmt.Errorf("commit transaction: %w", err)
	}

	return stats, nil
}

// envOrDefault returns the environment variable value or a default.
func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
