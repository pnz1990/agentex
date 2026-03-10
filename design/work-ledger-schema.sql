-- =============================================================================
-- Agentex Work Ledger SQLite Schema
-- Part of: epic #1827 (Structured work ledger)
-- Parent:  v1.0 Roadmap (#1821)
-- =============================================================================
--
-- This schema replaces ConfigMap string state with typed, queryable SQLite tables.
-- It is embedded inside the Go coordinator (#1825).
--
-- Migration mapping (ConfigMap field → SQLite):
--   taskQueue              → tasks WHERE status='queued'
--   activeAssignments      → tasks WHERE claimed_by IS NOT NULL AND status='claimed'
--   debateStats            → SELECT COUNT(*) FROM debates GROUP BY stance
--   enactedDecisions       → proposals WHERE status='enacted'
--   visionQueue            → tasks WHERE priority=1 (vision tier)
--   specializedAssignments → agent_activity WHERE action='claim' AND routing_type='specialized'
--   S3 debate outcomes     → debates table
--   S3 identity files      → agents + agent_activity + metrics tables
--   coordinator-state misc → coordinator_state KV table
-- =============================================================================

PRAGMA journal_mode=WAL;          -- Write-Ahead Logging for concurrent reads
PRAGMA foreign_keys=ON;           -- Enforce referential integrity
PRAGMA synchronous=NORMAL;        -- Balance durability vs. performance

-- =============================================================================
-- SCHEMA VERSION (for migrations)
-- =============================================================================

CREATE TABLE IF NOT EXISTS schema_migrations (
  version     INTEGER PRIMARY KEY,
  description TEXT NOT NULL,
  applied_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO schema_migrations (version, description) VALUES (1, 'Initial schema');

-- =============================================================================
-- TASKS
-- Replaces: taskQueue, activeAssignments, visionQueue ConfigMap fields
-- =============================================================================

CREATE TABLE IF NOT EXISTS tasks (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  github_issue    INTEGER NOT NULL UNIQUE,    -- GitHub issue number (unique constraint enables atomic claim)
  title           TEXT,
  status          TEXT NOT NULL DEFAULT 'queued'
                  CHECK(status IN ('queued','claimed','in_progress','pr_open','merged','done','failed','stale')),
  priority        INTEGER NOT NULL DEFAULT 5, -- 1=vision (highest), 5=normal, 10=low
  effort          TEXT CHECK(effort IN ('S','M','L','XL')),
  labels          TEXT,                       -- JSON array: ["enhancement","bug"]
  depends_on      TEXT,                       -- JSON array of github_issue numbers
  claimed_by      TEXT,                       -- agent name (FK to agents.name)
  claimed_at      TIMESTAMP,
  claim_timeout   TIMESTAMP,                  -- auto-release if agent goes silent (claimed_at + 30min)
  pr_number       INTEGER,
  pr_url          TEXT,
  pr_merged_at    TIMESTAMP,
  routing_type    TEXT CHECK(routing_type IN ('specialized','generic','vision','manual')),
  routed_to       TEXT,                       -- agent name if specialized routing was used
  source          TEXT NOT NULL DEFAULT 'github'
                  CHECK(source IN ('github','vision_queue','coordinator','manual')),
  vision_feature  TEXT,                       -- non-null if from vision queue (feature name)
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_tasks_status       ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_claimed_by   ON tasks(claimed_by);
CREATE INDEX IF NOT EXISTS idx_tasks_priority     ON tasks(priority, status);
CREATE INDEX IF NOT EXISTS idx_tasks_labels       ON tasks(labels);  -- for JSON text search

-- Trigger: keep updated_at current
CREATE TRIGGER IF NOT EXISTS tasks_updated_at
AFTER UPDATE ON tasks
BEGIN
  UPDATE tasks SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- =============================================================================
-- AGENTS
-- Replaces: activeAgents ConfigMap field, S3 identity files
-- =============================================================================

CREATE TABLE IF NOT EXISTS agents (
  name              TEXT PRIMARY KEY,           -- e.g. "worker-1773186205"
  display_name      TEXT,                       -- e.g. "ada"
  role              TEXT NOT NULL
                    CHECK(role IN ('planner','worker','reviewer','architect','god-delegate','coordinator','seed')),
  generation        INTEGER NOT NULL DEFAULT 0,
  status            TEXT NOT NULL DEFAULT 'active'
                    CHECK(status IN ('active','completed','failed','unknown')),
  specialization    TEXT,                       -- e.g. "debugger", "platform-specialist"
  specialization_labels TEXT,                  -- JSON object: {"enhancement":5,"bug":3}
  tasks_completed   INTEGER NOT NULL DEFAULT 0,
  issues_filed      INTEGER NOT NULL DEFAULT 0,
  prs_merged        INTEGER NOT NULL DEFAULT 0,
  thoughts_posted   INTEGER NOT NULL DEFAULT 0,
  debates_won       INTEGER NOT NULL DEFAULT 0,
  synthesis_count   INTEGER NOT NULL DEFAULT 0,
  cited_syntheses   INTEGER NOT NULL DEFAULT 0,
  debate_quality    INTEGER NOT NULL DEFAULT 0, -- (synthesis_count*2) + (cited_syntheses*5)
  vision_score_avg  REAL,                       -- rolling average from reports
  reputation_history TEXT,                      -- JSON array of {score, ts} (last 10)
  last_seen_at      TIMESTAMP,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_agents_role           ON agents(role, status);
CREATE INDEX IF NOT EXISTS idx_agents_specialization ON agents(specialization);
CREATE INDEX IF NOT EXISTS idx_agents_debate_quality ON agents(debate_quality DESC);

-- =============================================================================
-- AGENT ACTIVITY
-- Replaces: S3 identity stats, coordinator decisionLog
-- Every significant action an agent takes is logged here.
-- =============================================================================

CREATE TABLE IF NOT EXISTS agent_activity (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_name  TEXT NOT NULL REFERENCES agents(name) ON DELETE CASCADE,
  action      TEXT NOT NULL
              CHECK(action IN (
                'claim','unclaim','implement','pr_opened','pr_merged',
                'thought','debate','vote','report','spawn','spawn_blocked',
                'escalate','governance_proposal','governance_vote',
                'debate_synthesize','citation_received','mentor_credited',
                'task_done','task_failed','chronicle_candidate'
              )),
  target      TEXT,       -- issue number, PR number, thought name, etc.
  detail      TEXT,       -- JSON payload with action-specific data
  issue_num   INTEGER,    -- denormalized for fast per-issue queries
  session_id  TEXT,       -- groups all actions in one agent run
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_activity_agent      ON agent_activity(agent_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_action     ON agent_activity(action, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_issue      ON agent_activity(issue_num);
CREATE INDEX IF NOT EXISTS idx_activity_session    ON agent_activity(session_id);

-- =============================================================================
-- DEBATES
-- Replaces: S3 debates/ directory, debateStats ConfigMap field
-- Full debate thread reconstruction via parent_id chain.
-- =============================================================================

CREATE TABLE IF NOT EXISTS debates (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  thread_id   TEXT NOT NULL,                -- SHA256 of root thought name (groups a thread)
  parent_id   INTEGER REFERENCES debates(id), -- NULL = root of thread
  thought_ref TEXT,                         -- Kubernetes Thought ConfigMap name
  agent       TEXT NOT NULL REFERENCES agents(name) ON DELETE SET NULL,
  stance      TEXT NOT NULL
              CHECK(stance IN ('propose','agree','disagree','synthesize','abstain')),
  content     TEXT NOT NULL,
  confidence  INTEGER CHECK(confidence BETWEEN 1 AND 10),
  topic       TEXT,                         -- e.g. "circuit-breaker", "spawn-control"
  component   TEXT,                         -- e.g. "entrypoint.sh", "coordinator.sh"
  outcome     TEXT CHECK(outcome IN ('open','synthesized','consensus-agree','consensus-disagree','unresolved')),
  resolution  TEXT,                         -- synthesis text (non-null when outcome=synthesized)
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_debates_thread    ON debates(thread_id);
CREATE INDEX IF NOT EXISTS idx_debates_agent     ON debates(agent);
CREATE INDEX IF NOT EXISTS idx_debates_topic     ON debates(topic);
CREATE INDEX IF NOT EXISTS idx_debates_component ON debates(component);
CREATE INDEX IF NOT EXISTS idx_debates_outcome   ON debates(outcome);

-- =============================================================================
-- PROPOSALS (Governance)
-- Replaces: thoughtType=proposal ConfigMap entries, voteRegistry ConfigMap field
-- =============================================================================

CREATE TABLE IF NOT EXISTS proposals (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  topic       TEXT NOT NULL,                -- e.g. "circuit-breaker", "vision-feature"
  proposer    TEXT NOT NULL REFERENCES agents(name),
  content     TEXT NOT NULL,                -- full proposal text
  param_key   TEXT,                         -- e.g. "circuitBreakerLimit"
  param_value TEXT,                         -- e.g. "12"
  status      TEXT NOT NULL DEFAULT 'open'
              CHECK(status IN ('open','enacted','rejected','expired','withdrawn')),
  vote_approve INTEGER NOT NULL DEFAULT 0,
  vote_reject  INTEGER NOT NULL DEFAULT 0,
  vote_abstain INTEGER NOT NULL DEFAULT 0,
  threshold   INTEGER NOT NULL DEFAULT 3,   -- votes needed to enact
  enacted_at  TIMESTAMP,
  enacted_by  TEXT,                         -- coordinator agent name
  expires_at  TIMESTAMP,                    -- auto-expire after N hours
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_proposals_status ON proposals(status);
CREATE INDEX IF NOT EXISTS idx_proposals_topic  ON proposals(topic);

-- =============================================================================
-- VOTES
-- Replaces: voteRegistry ConfigMap field
-- UNIQUE(proposal_id, voter) enforces one-vote-per-agent.
-- =============================================================================

CREATE TABLE IF NOT EXISTS votes (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  proposal_id INTEGER NOT NULL REFERENCES proposals(id) ON DELETE CASCADE,
  voter       TEXT NOT NULL REFERENCES agents(name),
  stance      TEXT NOT NULL CHECK(stance IN ('approve','reject','abstain')),
  reason      TEXT,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(proposal_id, voter)                -- prevents double-voting
);

CREATE INDEX IF NOT EXISTS idx_votes_proposal ON votes(proposal_id);
CREATE INDEX IF NOT EXISTS idx_votes_voter    ON votes(voter);

-- Trigger: update vote counts in proposals when a vote is cast
CREATE TRIGGER IF NOT EXISTS votes_update_counts
AFTER INSERT ON votes
BEGIN
  UPDATE proposals SET
    vote_approve = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'approve'),
    vote_reject  = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'reject'),
    vote_abstain = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'abstain')
  WHERE id = NEW.proposal_id;
END;

-- =============================================================================
-- METRICS (Civilization-level counters)
-- Replaces: debateStats, specializedAssignments, genericAssignments ConfigMap fields
-- Time-series design: INSERT-only, never UPDATE. Query via aggregation.
-- =============================================================================

CREATE TABLE IF NOT EXISTS metrics (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  metric      TEXT NOT NULL,              -- 'debate_responses', 'tasks_completed', etc.
  value       INTEGER NOT NULL DEFAULT 1, -- typically 1 (increment); use -1 for decrements
  agent       TEXT,                       -- NULL = civilization-wide; non-NULL = per-agent
  labels      TEXT,                       -- JSON: {"stance":"disagree","issue":"1845"}
  recorded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_metrics_metric      ON metrics(metric, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_agent       ON metrics(agent, metric);
CREATE INDEX IF NOT EXISTS idx_metrics_recorded_at ON metrics(recorded_at);

-- Convenience view: current metric totals
CREATE VIEW IF NOT EXISTS metric_totals AS
SELECT
  metric,
  agent,
  SUM(value) AS total,
  COUNT(*)   AS event_count,
  MIN(recorded_at) AS first_recorded,
  MAX(recorded_at) AS last_recorded
FROM metrics
GROUP BY metric, agent;

-- =============================================================================
-- REPORTS (Agent exit reports)
-- Replaces: Report CRs in Kubernetes (which accumulate unboundedly)
-- =============================================================================

CREATE TABLE IF NOT EXISTS reports (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_name      TEXT NOT NULL REFERENCES agents(name),
  task_ref        TEXT,
  status          TEXT NOT NULL CHECK(status IN ('completed','failed','emergency')),
  vision_score    INTEGER CHECK(vision_score BETWEEN 1 AND 10),
  work_done       TEXT,                  -- freetext summary
  issues_found    TEXT,                  -- "#N, #N"
  pr_opened       TEXT,                  -- "PR #N"
  blockers        TEXT,
  next_priority   TEXT,
  generation      INTEGER,
  exit_code       INTEGER NOT NULL DEFAULT 0,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_reports_agent      ON reports(agent_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reports_vision     ON reports(vision_score);
CREATE INDEX IF NOT EXISTS idx_reports_created_at ON reports(created_at DESC);

-- =============================================================================
-- COORDINATOR STATE (KV store for misc coordinator fields)
-- Replaces: remaining coordinator-state ConfigMap fields not covered above
-- Provides a typed audit trail for every state change.
-- =============================================================================

CREATE TABLE IF NOT EXISTS coordinator_state (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_by  TEXT                                         -- agent name that wrote it
);

-- State change audit log
CREATE TABLE IF NOT EXISTS coordinator_state_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  key         TEXT NOT NULL,
  old_value   TEXT,
  new_value   TEXT NOT NULL,
  changed_by  TEXT,
  changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_state_log_key ON coordinator_state_log(key, changed_at DESC);

-- Trigger: log all coordinator_state changes
CREATE TRIGGER IF NOT EXISTS coordinator_state_audit
AFTER UPDATE ON coordinator_state
BEGIN
  INSERT INTO coordinator_state_log(key, old_value, new_value, changed_by, changed_at)
  VALUES (NEW.key, OLD.value, NEW.value, NEW.updated_by, CURRENT_TIMESTAMP);
END;

-- =============================================================================
-- SPAWN EVENTS (Track agent lifecycle)
-- Replaces: decisionLog entries about spawning, preClaimTimestamps
-- =============================================================================

CREATE TABLE IF NOT EXISTS spawn_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  spawner         TEXT,                  -- agent that spawned (NULL = planner-loop/system)
  spawned_name    TEXT NOT NULL,         -- new agent name
  spawned_role    TEXT NOT NULL,
  task_name       TEXT,
  issue_num       INTEGER,
  generation      INTEGER,
  outcome         TEXT NOT NULL
                  CHECK(outcome IN ('spawned','blocked_circuit','blocked_killswitch','blocked_coordinator','failed')),
  reason          TEXT,                  -- why blocked/failed
  spawned_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_spawn_events_spawner   ON spawn_events(spawner);
CREATE INDEX IF NOT EXISTS idx_spawn_events_spawned   ON spawn_events(spawned_name);
CREATE INDEX IF NOT EXISTS idx_spawn_events_outcome   ON spawn_events(outcome, spawned_at DESC);
CREATE INDEX IF NOT EXISTS idx_spawn_events_time      ON spawn_events(spawned_at DESC);

-- =============================================================================
-- TRUST GRAPH (Agent-to-agent citation relationships)
-- Replaces: agentTrustGraph ConfigMap field
-- =============================================================================

CREATE TABLE IF NOT EXISTS trust_edges (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  citing      TEXT NOT NULL REFERENCES agents(name),   -- agent who cited the synthesis
  cited       TEXT NOT NULL REFERENCES agents(name),   -- agent whose synthesis was cited
  thread_id   TEXT NOT NULL,                            -- which debate synthesis was cited
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(citing, cited, thread_id)                      -- prevents duplicate citations
);

CREATE INDEX IF NOT EXISTS idx_trust_cited   ON trust_edges(cited, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trust_citing  ON trust_edges(citing);

-- Convenience view: trust scores (number of citations received)
CREATE VIEW IF NOT EXISTS trust_scores AS
SELECT
  cited         AS agent,
  COUNT(*)      AS citation_count,
  COUNT(DISTINCT citing) AS unique_citers
FROM trust_edges
GROUP BY cited
ORDER BY citation_count DESC;

-- =============================================================================
-- CHRONICLE CANDIDATES
-- Replaces: coordinator-state.chronicleCandidates field
-- =============================================================================

CREATE TABLE IF NOT EXISTS chronicle_candidates (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  thought_ref TEXT NOT NULL UNIQUE,     -- Thought ConfigMap name
  era         TEXT NOT NULL,
  summary     TEXT NOT NULL,
  lesson      TEXT NOT NULL,
  milestone   TEXT,
  proposer    TEXT REFERENCES agents(name),
  confidence  INTEGER NOT NULL DEFAULT 9,
  status      TEXT NOT NULL DEFAULT 'pending'
              CHECK(status IN ('pending','accepted','rejected')),
  reviewed_at TIMESTAMP,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_chronicle_status ON chronicle_candidates(status, confidence DESC);

-- =============================================================================
-- QUERY EXAMPLES — Common operations
-- =============================================================================

-- Q1: Atomically claim a task (use SQLite's BEGIN EXCLUSIVE + UNIQUE constraint)
-- BEGIN EXCLUSIVE;
-- SELECT id, title FROM tasks WHERE github_issue = 1845 AND status = 'queued';
-- UPDATE tasks SET claimed_by = 'worker-123', claimed_at = CURRENT_TIMESTAMP,
--   claim_timeout = datetime(CURRENT_TIMESTAMP, '+30 minutes'), status = 'claimed'
-- WHERE github_issue = 1845 AND status = 'queued';  -- fails silently if already claimed
-- COMMIT;

-- Q2: List tasks assigned to a specific agent
-- SELECT t.github_issue, t.title, t.status, t.claimed_at
-- FROM tasks t WHERE t.claimed_by = 'worker-123' ORDER BY t.claimed_at DESC;

-- Q3: Find stale claims (agent gone silent for > 30 min)
-- SELECT github_issue, claimed_by, claim_timeout
-- FROM tasks WHERE status = 'claimed' AND claim_timeout < CURRENT_TIMESTAMP;

-- Q4: Full debate thread reconstruction
-- WITH RECURSIVE thread(id, parent_id, depth, agent, stance, content, topic, created_at) AS (
--   SELECT id, parent_id, 0, agent, stance, content, topic, created_at
--   FROM debates WHERE thread_id = 'abc123' AND parent_id IS NULL
--   UNION ALL
--   SELECT d.id, d.parent_id, t.depth+1, d.agent, d.stance, d.content, d.topic, d.created_at
--   FROM debates d JOIN thread t ON d.parent_id = t.id
-- )
-- SELECT * FROM thread ORDER BY depth, created_at;

-- Q5: Civilization debate statistics (replaces debateStats string)
-- SELECT
--   COUNT(*) AS total_responses,
--   COUNT(DISTINCT thread_id) AS total_threads,
--   SUM(CASE WHEN stance='disagree' THEN 1 ELSE 0 END) AS disagree_count,
--   SUM(CASE WHEN stance='synthesize' THEN 1 ELSE 0 END) AS synthesize_count
-- FROM debates;

-- Q6: Agent work history ("what has agent X done?")
-- SELECT action, target, detail, created_at
-- FROM agent_activity WHERE agent_name = 'worker-123'
-- ORDER BY created_at DESC LIMIT 50;

-- Q7: Governance proposals pending vote
-- SELECT p.id, p.topic, p.proposer, p.content, p.vote_approve, p.vote_reject, p.threshold
-- FROM proposals p WHERE p.status = 'open'
-- ORDER BY p.created_at DESC;

-- Q8: Check if 3+ agents approved a proposal (coordinator auto-enact check)
-- SELECT id FROM proposals
-- WHERE status = 'open' AND vote_approve >= threshold;

-- Q9: Agent leaderboard by vision score
-- SELECT a.display_name, a.name, a.role, a.specialization,
--        AVG(r.vision_score) AS avg_vision, COUNT(r.id) AS report_count
-- FROM agents a JOIN reports r ON r.agent_name = a.name
-- GROUP BY a.name ORDER BY avg_vision DESC LIMIT 10;

-- Q10: Spawn rate (anti-proliferation check — last 2 minutes)
-- SELECT COUNT(*) FROM spawn_events
-- WHERE outcome = 'spawned' AND spawned_at > datetime(CURRENT_TIMESTAMP, '-2 minutes');

-- Q11: Task throughput by day
-- SELECT DATE(updated_at) AS day, COUNT(*) AS tasks_completed
-- FROM tasks WHERE status IN ('done','merged') GROUP BY day ORDER BY day DESC;

-- Q12: Vision queue (tasks with priority=1, ordered)
-- SELECT github_issue, title, vision_feature, claimed_by, status
-- FROM tasks WHERE source = 'vision_queue' ORDER BY priority, created_at;

-- Q13: Specialized vs generic routing ratio
-- SELECT
--   SUM(CASE WHEN routing_type='specialized' THEN 1 ELSE 0 END) AS specialized,
--   SUM(CASE WHEN routing_type='generic' THEN 1 ELSE 0 END)     AS generic,
--   ROUND(100.0 * SUM(CASE WHEN routing_type='specialized' THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_specialized
-- FROM tasks WHERE routing_type IS NOT NULL;

-- Q14: Trust graph — top cited agents (replaces agentTrustGraph string)
-- SELECT * FROM trust_scores LIMIT 10;

-- =============================================================================
-- CONFIGMAP MIGRATION MAPPING
-- =============================================================================
-- 
-- coordinator-state ConfigMap field  → SQLite migration query
-- ─────────────────────────────────────────────────────────────────────────────
-- taskQueue: "1782,1783"
--   → INSERT INTO tasks(github_issue, status) VALUES (1782,'queued'),(1783,'queued')
--     ON CONFLICT(github_issue) DO NOTHING;
-- 
-- activeAssignments: "worker-123:676,worker-456:789"
--   → UPDATE tasks SET claimed_by='worker-123', status='claimed' WHERE github_issue=676;
--      UPDATE tasks SET claimed_by='worker-456', status='claimed' WHERE github_issue=789;
-- 
-- visionQueue: "feature:mentorship:2026-03-10:planner-42"
--   → INSERT INTO tasks(github_issue, title, source, priority, vision_feature)
--      SELECT NULL, 'mentorship', 'vision_queue', 1, 'mentorship'
--      WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE vision_feature='mentorship');
-- 
-- enactedDecisions: "circuitBreakerLimit=6|2026-03-09|4-votes"
--   → INSERT INTO proposals(topic, proposer, content, param_key, param_value, status, enacted_at)
--      VALUES ('circuit-breaker','(migrated)','circuitBreakerLimit=6','circuitBreakerLimit','6','enacted','2026-03-09');
-- 
-- debateStats: "responses=191 threads=110 disagree=37 synthesize=17"
--   → These are derived by querying the debates table. No direct migration needed.
--      The coordinator reads from the debates table going forward.
-- 
-- spawnSlots: "8"
--   → INSERT INTO coordinator_state(key, value) VALUES ('spawnSlots','8');
-- 
-- agentTrustGraph: "agentA:agentB:3|agentB:agentC:1"
--   → Parse and INSERT INTO trust_edges(citing, cited, thread_id) for each edge.
-- 
-- preClaimTimestamps: "agent1:123:1773186378;agent2:456:1773186400"
--   → SELECT into spawn_events or agent_activity with action='claim'
-- =============================================================================
