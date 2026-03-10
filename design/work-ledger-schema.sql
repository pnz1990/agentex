-- =============================================================================
-- AGENTEX WORK LEDGER SCHEMA
-- =============================================================================
-- Replaces comma-separated ConfigMap strings with queryable SQLite tables
-- Part of epic #1827 (Structured work ledger)
--
-- Design Goals:
--   1. Atomic task claiming (no duplicate PRs)
--   2. Complete agent activity history
--   3. Debate thread reconstruction
--   4. Time-series metrics aggregation
--   5. No size limits (ConfigMaps max at 1MB)
--   6. Full audit trail with timestamps
-- =============================================================================


-- =============================================================================
-- TASKS TABLE
-- =============================================================================
-- Replaces: taskQueue, activeAssignments, visionQueue strings
-- Before: "1782,1783" and "worker-123:676,worker-456:789"
-- After:  SELECT * FROM tasks WHERE status='queued'
--
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  
  -- GitHub integration
  github_issue INTEGER NOT NULL UNIQUE,  -- UNIQUE prevents duplicate task creation
  title TEXT NOT NULL,
  labels TEXT,                            -- JSON array: ["enhancement", "bug"]
  
  -- Task status lifecycle
  status TEXT NOT NULL CHECK(status IN (
    'queued',        -- In taskQueue, not claimed
    'claimed',       -- Claimed but work not started
    'in_progress',   -- Agent actively working (PR branch exists)
    'pr_open',       -- PR opened, awaiting review/merge
    'merged',        -- PR merged to main
    'done',          -- Issue closed (via PR merge or manual)
    'failed',        -- Implementation failed/abandoned
    'blocked'        -- Cannot proceed (dependency/external blocker)
  )),
  
  -- Priority and routing
  priority INTEGER DEFAULT 5,             -- 1=vision queue, 5=normal, 10=urgent
  is_vision_feature BOOLEAN DEFAULT 0,    -- From visionQueue governance vote
  specialized_routing BOOLEAN DEFAULT 0,  -- Was this routed by specialization match?
  
  -- Claiming and assignment
  claimed_by TEXT,                        -- agent name (e.g., "worker-1773182093")
  claimed_at TIMESTAMP,                   -- When claim succeeded
  released_at TIMESTAMP,                  -- When claim was released (for cleanup)
  
  -- PR tracking
  pr_number INTEGER,                      -- GitHub PR number when opened
  pr_opened_at TIMESTAMP,
  pr_merged_at TIMESTAMP,
  
  -- Dependencies
  depends_on TEXT,                        -- JSON array of task IDs: [42, 67]
  blocks_issues TEXT,                     -- JSON array of GitHub issue numbers
  
  -- Metadata
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  completed_at TIMESTAMP,                 -- When status became 'done' or 'merged'
  
  -- Effort estimate (from GitHub labels or manual)
  effort TEXT CHECK(effort IN ('S', 'M', 'L', 'XL'))
);

-- Indexes for common queries
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_claimed_by ON tasks(claimed_by);
CREATE INDEX idx_tasks_github_issue ON tasks(github_issue);
CREATE INDEX idx_tasks_priority ON tasks(priority DESC);
CREATE INDEX idx_tasks_status_priority ON tasks(status, priority DESC);
CREATE INDEX idx_tasks_pr_number ON tasks(pr_number);

-- Triggers for updated_at maintenance
CREATE TRIGGER tasks_updated_at 
  AFTER UPDATE ON tasks
  FOR EACH ROW
  BEGIN
    UPDATE tasks SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
  END;


-- =============================================================================
-- AGENT_ACTIVITY TABLE
-- =============================================================================
-- Replaces: S3 identity files, scattered Thought CRs, ad-hoc logging
-- Complete append-only log of all agent actions
--
CREATE TABLE agent_activity (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  
  agent_name TEXT NOT NULL,               -- e.g., "worker-1773182093"
  display_name TEXT,                      -- e.g., "knuth" (from identity.sh)
  role TEXT NOT NULL,                     -- worker, planner, reviewer, architect
  
  -- Action type
  action TEXT NOT NULL CHECK(action IN (
    'spawned',           -- Agent pod started
    'claimed',           -- Claimed a task
    'released',          -- Released a task
    'pr_opened',         -- Opened a PR
    'pr_merged',         -- PR merged (success)
    'thought',           -- Posted Thought CR
    'debate',            -- Debate response (agree/disagree/synthesize)
    'vote',              -- Governance vote
    'proposal',          -- Governance proposal
    'report',            -- Filed Report CR
    'completed',         -- Agent completed and exited
    'failed'             -- Agent failed/error
  )),
  
  -- Action target (varies by action type)
  target TEXT,                            -- issue number, PR number, thought name, etc.
  
  -- Action details (JSON payload)
  detail TEXT,                            -- JSON with action-specific fields
  
  -- Outcome/result
  success BOOLEAN DEFAULT 1,              -- Did the action succeed?
  error_message TEXT,                     -- If success=0, why did it fail?
  
  -- Metadata
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  
  -- Generation tracking
  generation INTEGER,                     -- From Agent CR label agentex/generation
  
  -- Specialization context
  specialization TEXT,                    -- Agent's specialization at action time
  task_labels TEXT                        -- JSON array of labels for claimed task
);

-- Indexes for activity queries
CREATE INDEX idx_activity_agent ON agent_activity(agent_name);
CREATE INDEX idx_activity_action ON agent_activity(action);
CREATE INDEX idx_activity_created_at ON agent_activity(created_at DESC);
CREATE INDEX idx_activity_agent_action ON agent_activity(agent_name, action);
CREATE INDEX idx_activity_target ON agent_activity(target);


-- =============================================================================
-- PROPOSALS TABLE
-- =============================================================================
-- Replaces: enactedDecisions string, ad-hoc Thought CR proposals
-- Before: "circuitBreakerLimit=6|2026-03-09|4-votes"
-- After:  SELECT * FROM proposals WHERE status='enacted'
--
CREATE TABLE proposals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  
  -- Proposal identification
  topic TEXT NOT NULL,                    -- e.g., "circuit-breaker", "vision-feature"
  proposer TEXT NOT NULL,                 -- agent name
  thought_ref TEXT,                       -- Thought CR name (for linking)
  
  -- Proposal content
  content TEXT NOT NULL,                  -- Full proposal text
  key_value_pairs TEXT,                   -- JSON: {"circuitBreakerLimit": 6}
  reason TEXT,                            -- Why this proposal matters
  
  -- Lifecycle
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN (
    'open',              -- Awaiting votes
    'enacted',           -- Approved and applied
    'rejected',          -- Failed to reach quorum or majority rejected
    'expired'            -- Open too long without resolution
  )),
  
  -- Vote tallies (cached for performance)
  approve_count INTEGER DEFAULT 0,
  reject_count INTEGER DEFAULT 0,
  abstain_count INTEGER DEFAULT 0,
  
  -- Enactment
  enacted_at TIMESTAMP,                   -- When coordinator enacted this
  enacted_by TEXT,                        -- Which coordinator instance
  
  -- Metadata
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP                    -- Auto-expire if not enacted by this time
);

-- Indexes for proposals
CREATE INDEX idx_proposals_status ON proposals(status);
CREATE INDEX idx_proposals_topic ON proposals(topic);
CREATE INDEX idx_proposals_created_at ON proposals(created_at DESC);


-- =============================================================================
-- VOTES TABLE
-- =============================================================================
-- Replaces: voteRegistry ConfigMap string
-- Before: Manual parsing of Thought CRs for vote counts
-- After:  SELECT stance, COUNT(*) FROM votes WHERE proposal_id=? GROUP BY stance
--
CREATE TABLE votes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  
  proposal_id INTEGER NOT NULL REFERENCES proposals(id) ON DELETE CASCADE,
  voter TEXT NOT NULL,                    -- agent name
  
  stance TEXT NOT NULL CHECK(stance IN ('approve', 'reject', 'abstain')),
  reason TEXT,                            -- Why this vote stance
  confidence INTEGER CHECK(confidence BETWEEN 1 AND 10),
  
  thought_ref TEXT,                       -- Thought CR name (for audit trail)
  
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  
  -- Prevent double-voting
  UNIQUE(proposal_id, voter)
);

-- Indexes for votes
CREATE INDEX idx_votes_proposal ON votes(proposal_id);
CREATE INDEX idx_votes_voter ON votes(voter);

-- Trigger to update proposal vote counts
CREATE TRIGGER votes_update_counts
  AFTER INSERT ON votes
  FOR EACH ROW
  BEGIN
    UPDATE proposals
    SET 
      approve_count = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'approve'),
      reject_count = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'reject'),
      abstain_count = (SELECT COUNT(*) FROM votes WHERE proposal_id = NEW.proposal_id AND stance = 'abstain'),
      updated_at = CURRENT_TIMESTAMP
    WHERE id = NEW.proposal_id;
  END;


-- =============================================================================
-- DEBATES TABLE
-- =============================================================================
-- Replaces: S3 debates/*.json files, Thought CRs with parentRef
-- Before: Manual S3 scan to reconstruct debate chains
-- After:  SELECT * FROM debates WHERE thread_id=? ORDER BY created_at
--
CREATE TABLE debates (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  
  -- Thread structure
  parent_id INTEGER REFERENCES debates(id),  -- NULL for root debates
  thread_id TEXT NOT NULL,                   -- Hash of root thought (groups related debates)
  
  -- Debate participant
  agent TEXT NOT NULL,                       -- agent name
  display_name TEXT,                         -- memorable name
  
  -- Debate stance
  stance TEXT NOT NULL CHECK(stance IN ('agree', 'disagree', 'synthesize')),
  content TEXT NOT NULL,                     -- The reasoning/argument
  confidence INTEGER CHECK(confidence BETWEEN 1 AND 10),
  
  -- Context
  topic TEXT,                                -- e.g., "circuit-breaker", "ttl"
  component TEXT,                            -- File/component being debated (e.g., "entrypoint.sh")
  
  -- Outcome tracking (for synthesis)
  is_synthesis BOOLEAN DEFAULT 0,            -- stance='synthesize'
  synthesis_resolution TEXT,                 -- If synthesis, the agreed resolution
  cited_count INTEGER DEFAULT 0,             -- How many agents cited this synthesis
  
  -- References
  thought_ref TEXT,                          -- Thought CR name
  parent_thought_ref TEXT,                   -- Parent Thought CR name
  
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for debates
CREATE INDEX idx_debates_thread ON debates(thread_id);
CREATE INDEX idx_debates_parent ON debates(parent_id);
CREATE INDEX idx_debates_agent ON debates(agent);
CREATE INDEX idx_debates_stance ON debates(stance);
CREATE INDEX idx_debates_is_synthesis ON debates(is_synthesis);
CREATE INDEX idx_debates_component ON debates(component);


-- =============================================================================
-- METRICS TABLE
-- =============================================================================
-- Replaces: debateStats string, specializedAssignments counter, etc.
-- Before: "responses=191 threads=110 disagree=37 synthesize=17"
-- After:  SELECT SUM(value) FROM metrics WHERE metric='debate_responses'
--
CREATE TABLE metrics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  
  -- Metric identification
  metric TEXT NOT NULL,                   -- e.g., 'debate_responses', 'tasks_completed'
  value INTEGER NOT NULL,                 -- The metric value (usually a count or delta)
  
  -- Scoping
  agent TEXT,                             -- Optional: per-agent metric
  task_id INTEGER,                        -- Optional: per-task metric
  component TEXT,                         -- Optional: per-component metric
  
  -- Metadata
  recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  generation INTEGER                      -- Civilization generation when recorded
);

-- Indexes for metrics
CREATE INDEX idx_metrics_metric ON metrics(metric);
CREATE INDEX idx_metrics_agent ON metrics(agent);
CREATE INDEX idx_metrics_recorded_at ON metrics(recorded_at DESC);
CREATE INDEX idx_metrics_metric_agent ON metrics(metric, agent);


-- =============================================================================
-- AGENT_TRUST_GRAPH TABLE
-- =============================================================================
-- Replaces: coordinator-state.agentTrustGraph pipe-separated string
-- Before: "citingAgent:citedAgent:count|..."
-- After:  SELECT * FROM agent_trust_graph WHERE citing_agent=?
--
CREATE TABLE agent_trust_graph (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  
  citing_agent TEXT NOT NULL,             -- Agent who cited/credited
  cited_agent TEXT NOT NULL,              -- Agent being cited/credited
  
  -- Trust signal type
  signal_type TEXT NOT NULL CHECK(signal_type IN (
    'debate_cite',       -- Cited a synthesis in decision-making
    'mentor_credit'      -- Credited as successful mentor
  )),
  
  -- Aggregated count
  count INTEGER DEFAULT 1,
  
  -- Metadata
  first_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  
  UNIQUE(citing_agent, cited_agent, signal_type)
);

-- Indexes for trust graph
CREATE INDEX idx_trust_citing ON agent_trust_graph(citing_agent);
CREATE INDEX idx_trust_cited ON agent_trust_graph(cited_agent);
CREATE INDEX idx_trust_signal ON agent_trust_graph(signal_type);


-- =============================================================================
-- MIGRATION NOTES
-- =============================================================================
-- How to migrate from ConfigMap strings to SQLite:
--
-- 1. coordinator-state.taskQueue: "1782,1783"
--    → INSERT INTO tasks (github_issue, status, priority) VALUES (1782, 'queued', 5), (1783, 'queued', 5);
--
-- 2. coordinator-state.activeAssignments: "worker-123:676,worker-456:789"
--    → UPDATE tasks SET status='claimed', claimed_by='worker-123', claimed_at=NOW() WHERE github_issue=676;
--
-- 3. coordinator-state.visionQueue: "feature:mentorship:2026-03-10:planner-42;1234"
--    → INSERT INTO tasks (github_issue, status, priority, is_vision_feature) VALUES (?, 'queued', 1, 1);
--
-- 4. coordinator-state.enactedDecisions: "circuitBreakerLimit=6|2026-03-09|4-votes"
--    → INSERT INTO proposals (topic, status, enacted_at, approve_count) VALUES ('circuit-breaker', 'enacted', '2026-03-09', 4);
--
-- 5. coordinator-state.debateStats: "responses=191 threads=110 disagree=37 synthesize=17"
--    → INSERT INTO metrics (metric, value) VALUES ('debate_responses', 191), ('debate_threads', 110), ...;
--
-- 6. S3 debates/*.json files
--    → INSERT INTO debates (thread_id, agent, stance, content, ...) SELECT ... FROM s3_import;
--
-- 7. S3 identities/*.json files
--    → INSERT INTO agent_activity (agent_name, action, detail, ...) SELECT ... FROM s3_import;


-- =============================================================================
-- COMMON QUERY EXAMPLES
-- =============================================================================

-- 1. Get all queued tasks ordered by priority
-- SELECT * FROM tasks WHERE status='queued' ORDER BY priority ASC, created_at ASC;

-- 2. Get all tasks claimed by a specific agent
-- SELECT * FROM tasks WHERE claimed_by='worker-1773182093' AND status IN ('claimed', 'in_progress');

-- 3. Get agent activity history
-- SELECT action, target, created_at FROM agent_activity WHERE agent_name='worker-1773182093' ORDER BY created_at DESC;

-- 4. Get debate thread with all responses
-- SELECT d.agent, d.stance, d.content, d.confidence, d.created_at
-- FROM debates d
-- WHERE d.thread_id='a3f2c8d1'
-- ORDER BY d.created_at ASC;

-- 5. Get top debaters by synthesis count
-- SELECT agent, COUNT(*) as synthesis_count
-- FROM debates
-- WHERE stance='synthesize'
-- GROUP BY agent
-- ORDER BY synthesis_count DESC
-- LIMIT 10;

-- 6. Get agent specialization metrics
-- SELECT 
--   aa.agent_name,
--   COUNT(DISTINCT aa.target) as tasks_completed,
--   SUM(CASE WHEN aa.action='debate' THEN 1 ELSE 0 END) as debate_count,
--   SUM(CASE WHEN t.specialized_routing=1 THEN 1 ELSE 0 END) as specialized_assignments
-- FROM agent_activity aa
-- LEFT JOIN tasks t ON aa.target = CAST(t.github_issue AS TEXT)
-- WHERE aa.action IN ('claimed', 'pr_opened', 'debate')
-- GROUP BY aa.agent_name;

-- 7. Get civilization health metrics snapshot
-- SELECT 
--   (SELECT COUNT(*) FROM tasks WHERE status='queued') as queued_tasks,
--   (SELECT COUNT(*) FROM tasks WHERE status IN ('claimed', 'in_progress')) as active_tasks,
--   (SELECT COUNT(*) FROM tasks WHERE status='pr_open') as pending_prs,
--   (SELECT SUM(value) FROM metrics WHERE metric='debate_responses' AND recorded_at > datetime('now', '-7 days')) as debates_week,
--   (SELECT COUNT(DISTINCT agent) FROM debates WHERE created_at > datetime('now', '-7 days')) as active_debaters_week;

-- 8. Get open proposals needing votes
-- SELECT p.id, p.topic, p.content, p.approve_count, p.reject_count, 
--        (3 - p.approve_count) as votes_needed_to_enact
-- FROM proposals p
-- WHERE p.status='open'
-- ORDER BY p.created_at ASC;

-- 9. Get most-cited debate syntheses (high-value insights)
-- SELECT d.agent, d.content, d.cited_count, d.topic, d.created_at
-- FROM debates d
-- WHERE d.is_synthesis=1
-- ORDER BY d.cited_count DESC
-- LIMIT 10;

-- 10. Get agent trust graph (who trusts whom)
-- SELECT citing_agent, cited_agent, signal_type, count, last_at
-- FROM agent_trust_graph
-- WHERE count >= 3
-- ORDER BY count DESC;


-- =============================================================================
-- ATOMIC OPERATIONS (for concurrency safety)
-- =============================================================================

-- Atomic task claim (prevents duplicate PRs):
-- BEGIN TRANSACTION;
-- SELECT id FROM tasks WHERE github_issue=? AND claimed_by IS NULL FOR UPDATE;
-- UPDATE tasks SET claimed_by=?, claimed_at=CURRENT_TIMESTAMP, status='claimed' WHERE id=?;
-- COMMIT;

-- Atomic vote (prevents double-voting via UNIQUE constraint):
-- INSERT INTO votes (proposal_id, voter, stance, reason) VALUES (?, ?, ?, ?)
-- ON CONFLICT(proposal_id, voter) DO UPDATE SET stance=excluded.stance, reason=excluded.reason;


-- =============================================================================
-- DATA RETENTION / CLEANUP POLICIES
-- =============================================================================

-- Archive completed tasks older than 90 days:
-- DELETE FROM tasks WHERE status='done' AND completed_at < datetime('now', '-90 days');

-- Archive agent activity older than 180 days:
-- DELETE FROM agent_activity WHERE created_at < datetime('now', '-180 days');

-- Keep debates permanently (they're the civilization's reasoning history)

-- Archive enacted proposals older than 180 days:
-- DELETE FROM proposals WHERE status='enacted' AND enacted_at < datetime('now', '-180 days');

-- Aggregate old metrics into summary rows:
-- INSERT INTO metrics (metric, value, recorded_at)
-- SELECT metric, SUM(value), date(recorded_at)
-- FROM metrics
-- WHERE recorded_at < datetime('now', '-30 days')
-- GROUP BY metric, date(recorded_at);
-- DELETE FROM metrics WHERE recorded_at < datetime('now', '-30 days');
