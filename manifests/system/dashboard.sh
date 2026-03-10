#!/bin/bash
# Real-time Agentex Observability Dashboard
#
# Serves an HTML dashboard with live data from kubectl and GitHub.
# Requires: kubectl, gh, jq, python3 (or python)
#
# Usage:
#   ./dashboard.sh              # Start web dashboard on port 8081
#   ./dashboard.sh --port 9090  # Custom port
#   ./dashboard.sh --tui        # Terminal (TUI) mode — no browser needed
#   ./dashboard.sh --once       # Print snapshot and exit (for scripting)
#
# Once running, open: http://localhost:<port>/
# The dashboard auto-refreshes every 5 seconds via JavaScript.

set -euo pipefail

NAMESPACE="agentex"
PORT=8081
MODE="web"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --tui)  MODE="tui"; shift ;;
    --once) MODE="once"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Read constitution values (no hardcoding) ─────────────────────────────────
REPO=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.githubRepo}' 2>/dev/null || echo "pnz1990/agentex")
CIRCUIT_BREAKER_LIMIT=$(kubectl get configmap agentex-constitution -n "$NAMESPACE" \
  -o jsonpath='{.data.circuitBreakerLimit}' 2>/dev/null || echo "10")
if ! [[ "$CIRCUIT_BREAKER_LIMIT" =~ ^[0-9]+$ ]]; then CIRCUIT_BREAKER_LIMIT=10; fi

# ─── Data collection functions ────────────────────────────────────────────────

collect_agents() {
  # Returns JSON: [{name, role, status, age_min}]
  kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null | jq -r '
    .items[] |
    {
      name: .metadata.name,
      role: (.metadata.labels.role // "unknown"),
      active: (.status.active // 0),
      succeeded: (.status.succeeded // 0),
      failed: (.status.failed // 0),
      startTime: (.status.startTime // .metadata.creationTimestamp),
      completionTime: (.status.completionTime // null)
    } |
    . + {
      status: (
        if .completionTime != null then "done"
        elif .failed > 0 then "failed"
        elif .active > 0 then "running"
        else "pending"
        end
      )
    }
  ' 2>/dev/null | jq -s '.'
}

collect_coordinator() {
  # Returns key coordinator-state fields
  kubectl get configmap coordinator-state -n "$NAMESPACE" -o json 2>/dev/null | \
    jq '{
      taskQueue: (.data.taskQueue // ""),
      activeAssignments: (.data.activeAssignments // ""),
      debateStats: (.data.debateStats // ""),
      visionQueue: (.data.visionQueue // ""),
      lastHeartbeat: (.data.lastHeartbeat // ""),
      phase: (.data.phase // "Unknown"),
      spawnSlots: (.data.spawnSlots // ""),
      unresolvedDebates: (.data.unresolvedDebates // ""),
      v05MilestoneStatus: (.data.v05MilestoneStatus // ""),
      v05CriteriaStatus: (.data.v05CriteriaStatus // ""),
      specializedAssignments: (.data.specializedAssignments // "0"),
      genericAssignments: (.data.genericAssignments // "0")
    }' 2>/dev/null || echo '{}'
}

collect_thoughts() {
  # Returns last 10 thoughts
  kubectl get configmaps -n "$NAMESPACE" -l agentex/thought -o json 2>/dev/null | \
    jq '[.items | sort_by(.metadata.creationTimestamp) | reverse | .[0:10] | .[] |
      {
        name: .metadata.name,
        agent: (.data.agentRef // "?"),
        type: (.data.thoughtType // "?"),
        confidence: (.data.confidence // "?"),
        content: (.data.content // "" | .[0:120]),
        ts: .metadata.creationTimestamp
      }
    ]' 2>/dev/null || echo '[]'
}

collect_reports() {
  # Returns last 5 reports
  kubectl get configmaps -n "$NAMESPACE" -l agentex/report -o json 2>/dev/null | \
    jq '[.items | sort_by(.metadata.creationTimestamp) | reverse | .[0:5] | .[] |
      {
        agent: (.data.agentRef // "?"),
        role: (.data.role // "?"),
        status: (.data.status // "?"),
        visionScore: (.data.visionScore // "?"),
        workDone: (.data.workDone // "" | .[0:120]),
        ts: .metadata.creationTimestamp
      }
    ]' 2>/dev/null || echo '[]'
}

collect_proposals() {
  # Open proposals waiting for votes
  kubectl get configmaps -n "$NAMESPACE" -l agentex/thought -o json 2>/dev/null | \
    jq '[.items[] | select(.data.thoughtType == "proposal") |
      {
        name: .metadata.name,
        agent: (.data.agentRef // "?"),
        content: (.data.content // ""),
        ts: .metadata.creationTimestamp
      }
    ] | sort_by(.ts) | reverse | .[0:5]' 2>/dev/null || echo '[]'
}

collect_github() {
  OPEN_PRS=$(gh pr list --repo "$REPO" --state open --limit 100 --json number 2>/dev/null | \
    jq 'length' 2>/dev/null || echo "?")
  OPEN_ISSUES=$(gh issue list --repo "$REPO" --state open --limit 100 --json number 2>/dev/null | \
    jq 'length' 2>/dev/null || echo "?")
  RECENT_PRS=$(gh pr list --repo "$REPO" --state open --limit 5 \
    --json number,title,createdAt 2>/dev/null || echo "[]")
  printf '{"open_prs":%s,"open_issues":%s,"recent_prs":%s}' \
    "$OPEN_PRS" "$OPEN_ISSUES" "$RECENT_PRS"
}

collect_killswitch() {
  ENABLED=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.enabled}' 2>/dev/null || echo "false")
  REASON=$(kubectl get configmap agentex-killswitch -n "$NAMESPACE" \
    -o jsonpath='{.data.reason}' 2>/dev/null || echo "")
  printf '{"enabled":"%s","reason":"%s"}' "$ENABLED" "$REASON"
}

# ─── TUI mode ─────────────────────────────────────────────────────────────────

print_tui() {
  local RED='\033[0;31m'
  local GREEN='\033[0;32m'
  local YELLOW='\033[1;33m'
  local BLUE='\033[0;34m'
  local CYAN='\033[0;36m'
  local BOLD='\033[1m'
  local NC='\033[0m'

  clear
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       AGENTEX REAL-TIME OBSERVABILITY DASHBOARD              ║${NC}"
  printf  "${BOLD}║       %s  (ctrl+c to exit)                   ║${NC}\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # ── Agents ──
  echo -e "${CYAN}┌─ AGENTS ──────────────────────────────────────────────────────┐${NC}"
  AGENTS_JSON=$(collect_agents)
  ACTIVE_COUNT=$(echo "$AGENTS_JSON" | jq '[.[] | select(.status == "running")] | length')
  DONE_COUNT=$(echo "$AGENTS_JSON" | jq '[.[] | select(.status == "done")] | length')
  FAILED_COUNT=$(echo "$AGENTS_JSON" | jq '[.[] | select(.status == "failed")] | length')

  echo "$AGENTS_JSON" | jq -r '.[] | select(.status == "running") |
    "│ \u25cf \(.name[0:30])  \(.role[0:10])  running"' | \
    while IFS= read -r line; do echo -e "${CYAN}${line}${NC}"; done

  echo "$AGENTS_JSON" | jq -r '.[] | select(.status == "failed") |
    "│ \u2715 \(.name[0:30])  \(.role[0:10])  failed"' | \
    while IFS= read -r line; do echo -e "${RED}${line}${NC}"; done

  printf "${CYAN}│ Active: %d  Done: %d  Failed: %d${NC}\n" \
    "$ACTIVE_COUNT" "$DONE_COUNT" "$FAILED_COUNT"
  echo -e "${CYAN}└───────────────────────────────────────────────────────────────┘${NC}"
  echo ""

  # ── Coordinator / Work Queue ──
  echo -e "${CYAN}┌─ WORK QUEUE ───────────────────────────────────────────────────┐${NC}"
  COORD=$(collect_coordinator)
  TASK_QUEUE=$(echo "$COORD" | jq -r '.taskQueue')
  ACTIVE_ASSIGN=$(echo "$COORD" | jq -r '.activeAssignments')
  PHASE=$(echo "$COORD" | jq -r '.phase')
  HEARTBEAT=$(echo "$COORD" | jq -r '.lastHeartbeat')
  UNRESOLVED=$(echo "$COORD" | jq -r '.unresolvedDebates')

  echo -e "${CYAN}│ Coordinator phase: ${BOLD}${PHASE}${NC}${CYAN}  Last heartbeat: ${HEARTBEAT}${NC}"
  echo -e "${CYAN}│ Queue: ${TASK_QUEUE:0:60}${NC}"
  echo -e "${CYAN}│ Active: ${ACTIVE_ASSIGN:0:60}${NC}"
  [ -n "$UNRESOLVED" ] && \
    echo -e "${YELLOW}│ Unresolved debates: ${UNRESOLVED:0:60}${NC}"
  echo -e "${CYAN}└───────────────────────────────────────────────────────────────┘${NC}"
  echo ""

  # ── Recent Thoughts ──
  echo -e "${CYAN}┌─ RECENT THOUGHTS ──────────────────────────────────────────────┐${NC}"
  collect_thoughts | jq -r '.[] |
    "│ \(.ts[11:19]) [\(.type[0:8])] \(.agent[0:20]) — \(.content[0:50])"' | \
    while IFS= read -r line; do echo -e "${CYAN}${line}${NC}"; done
  echo -e "${CYAN}└───────────────────────────────────────────────────────────────┘${NC}"
  echo ""

  # ── Governance / Debate ──
  echo -e "${CYAN}┌─ GOVERNANCE & DEBATE ──────────────────────────────────────────┐${NC}"
  DEBATE_STATS=$(echo "$COORD" | jq -r '.debateStats')
  VISION_QUEUE=$(echo "$COORD" | jq -r '.visionQueue')
  echo -e "${CYAN}│ Debate stats: ${DEBATE_STATS}${NC}"
  [ -n "$VISION_QUEUE" ] && \
    echo -e "${CYAN}│ Vision queue: ${VISION_QUEUE:0:80}${NC}"
  echo ""
  collect_proposals | jq -r '.[] |
    "│ PROPOSAL [\(.agent[0:15])]: \(.content[0:60])"' | \
    while IFS= read -r line; do echo -e "${YELLOW}${line}${NC}"; done
  echo -e "${CYAN}└───────────────────────────────────────────────────────────────┘${NC}"
  echo ""

  # ── Kill switch + circuit breaker ──
  ACTIVE_JOBS=$(echo "$AGENTS_JSON" | jq '[.[] | select(.status == "running")] | length')
  KILLSWITCH=$(collect_killswitch)
  KS_ENABLED=$(echo "$KILLSWITCH" | jq -r '.enabled')

  echo -e "${CYAN}┌─ PROBLEMS & HEALTH ────────────────────────────────────────────┐${NC}"
  # Circuit breaker
  if [ "$ACTIVE_JOBS" -ge "$CIRCUIT_BREAKER_LIMIT" ]; then
    echo -e "${RED}│ ✗ Circuit breaker ACTIVATED (${ACTIVE_JOBS}/${CIRCUIT_BREAKER_LIMIT} jobs)${NC}"
  elif [ "$ACTIVE_JOBS" -gt $((CIRCUIT_BREAKER_LIMIT * 80 / 100)) ]; then
    echo -e "${YELLOW}│ ⚠ Circuit breaker at ${ACTIVE_JOBS}/${CIRCUIT_BREAKER_LIMIT} (>80%)${NC}"
  else
    echo -e "${GREEN}│ ✓ Circuit breaker OK (${ACTIVE_JOBS}/${CIRCUIT_BREAKER_LIMIT})${NC}"
  fi
  # Kill switch
  if [ "$KS_ENABLED" = "true" ]; then
    echo -e "${RED}│ ✗ Kill switch ACTIVE${NC}"
  else
    echo -e "${GREEN}│ ✓ Kill switch inactive${NC}"
  fi
  # Failed agents
  if [ "$FAILED_COUNT" -gt 0 ]; then
    echo -e "${RED}│ ✗ ${FAILED_COUNT} failed agents${NC}"
  fi

  # Milestone status
  V05=$(echo "$COORD" | jq -r '.v05MilestoneStatus')
  [ -n "$V05" ] && echo -e "${GREEN}│ ✓ v0.5 milestone: ${V05}${NC}"

  echo -e "${CYAN}└───────────────────────────────────────────────────────────────┘${NC}"
}

# ─── JSON snapshot for the web dashboard ─────────────────────────────────────

collect_snapshot() {
  local AGENTS_JSON COORD_JSON THOUGHTS_JSON REPORTS_JSON PROPOSALS_JSON GITHUB_JSON KS_JSON
  AGENTS_JSON=$(collect_agents)
  COORD_JSON=$(collect_coordinator)
  THOUGHTS_JSON=$(collect_thoughts)
  REPORTS_JSON=$(collect_reports)
  PROPOSALS_JSON=$(collect_proposals)
  GITHUB_JSON=$(collect_github)
  KS_JSON=$(collect_killswitch)

  ACTIVE_JOBS=$(echo "$AGENTS_JSON" | jq '[.[] | select(.status == "running")] | length')
  DONE_JOBS=$(echo "$AGENTS_JSON" | jq '[.[] | select(.status == "done")] | length')
  FAILED_JOBS=$(echo "$AGENTS_JSON" | jq '[.[] | select(.status == "failed")] | length')

  jq -n \
    --argjson agents "$AGENTS_JSON" \
    --argjson coordinator "$COORD_JSON" \
    --argjson thoughts "$THOUGHTS_JSON" \
    --argjson reports "$REPORTS_JSON" \
    --argjson proposals "$PROPOSALS_JSON" \
    --argjson github "$GITHUB_JSON" \
    --argjson killswitch "$KS_JSON" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson circuit_limit "$CIRCUIT_BREAKER_LIMIT" \
    --argjson active "$ACTIVE_JOBS" \
    --argjson done "$DONE_JOBS" \
    --argjson failed "$FAILED_JOBS" \
    '{
      timestamp: $ts,
      summary: {
        active_agents: $active,
        done_agents: $done,
        failed_agents: $failed,
        circuit_breaker_limit: $circuit_limit,
        circuit_breaker_pct: (($active * 100) / ($circuit_limit | if . == 0 then 1 else . end))
      },
      agents: $agents,
      coordinator: $coordinator,
      thoughts: $thoughts,
      reports: $reports,
      proposals: $proposals,
      github: $github,
      killswitch: $killswitch
    }'
}

# ─── HTML dashboard template ──────────────────────────────────────────────────

HTML_TEMPLATE='<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Agentex Dashboard</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: "JetBrains Mono", "Fira Code", monospace;
      background: #0d1117;
      color: #c9d1d9;
      font-size: 13px;
    }
    header {
      background: #161b22;
      border-bottom: 1px solid #30363d;
      padding: 12px 20px;
      display: flex;
      align-items: center;
      gap: 16px;
    }
    header h1 { font-size: 16px; color: #58a6ff; font-weight: 600; }
    #status-dot { width: 10px; height: 10px; border-radius: 50%; background: #3fb950; display: inline-block; }
    #last-update { font-size: 11px; color: #8b949e; margin-left: auto; }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(380px, 1fr));
      gap: 12px;
      padding: 12px;
    }
    .panel {
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 6px;
      overflow: hidden;
    }
    .panel-header {
      background: #21262d;
      padding: 8px 12px;
      font-size: 11px;
      font-weight: 600;
      color: #8b949e;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      display: flex;
      justify-content: space-between;
    }
    .panel-body { padding: 10px 12px; }
    .agent-row {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 3px 0;
      border-bottom: 1px solid #21262d;
    }
    .agent-row:last-child { border-bottom: none; }
    .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
    .dot.running  { background: #3fb950; }
    .dot.done     { background: #8b949e; }
    .dot.failed   { background: #f85149; }
    .dot.pending  { background: #d29922; }
    .agent-name { color: #58a6ff; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .agent-role { color: #8b949e; font-size: 11px; width: 80px; }
    .agent-status { font-size: 11px; width: 60px; }
    .status-running  { color: #3fb950; }
    .status-done     { color: #8b949e; }
    .status-failed   { color: #f85149; }
    .status-pending  { color: #d29922; }
    .summary-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 8px;
      margin-bottom: 10px;
    }
    .summary-item { text-align: center; }
    .summary-num  { font-size: 22px; font-weight: 700; color: #58a6ff; }
    .summary-label{ font-size: 10px; color: #8b949e; }
    .meter-bar {
      background: #21262d;
      border-radius: 4px;
      height: 6px;
      overflow: hidden;
      margin: 4px 0;
    }
    .meter-fill {
      height: 100%;
      border-radius: 4px;
      transition: width 0.5s;
    }
    .meter-fill.ok      { background: #3fb950; }
    .meter-fill.warn    { background: #d29922; }
    .meter-fill.danger  { background: #f85149; }
    .thought-row {
      display: flex;
      gap: 8px;
      padding: 4px 0;
      border-bottom: 1px solid #21262d;
      align-items: flex-start;
    }
    .thought-row:last-child { border-bottom: none; }
    .thought-ts   { color: #8b949e; font-size: 11px; white-space: nowrap; flex-shrink: 0; }
    .thought-type {
      font-size: 10px;
      padding: 1px 5px;
      border-radius: 3px;
      flex-shrink: 0;
      background: #21262d;
      color: #8b949e;
      white-space: nowrap;
    }
    .thought-type.insight   { background: #1f4e79; color: #79c0ff; }
    .thought-type.debate    { background: #3d1f1f; color: #ffa657; }
    .thought-type.proposal  { background: #1f3e1f; color: #3fb950; }
    .thought-type.vote      { background: #3d3d1f; color: #d29922; }
    .thought-type.blocker   { background: #4d1f1f; color: #f85149; }
    .thought-agent{ color: #58a6ff; flex-shrink: 0; max-width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .thought-content { color: #8b949e; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .report-row {
      padding: 4px 0;
      border-bottom: 1px solid #21262d;
    }
    .report-row:last-child { border-bottom: none; }
    .report-agent { color: #58a6ff; }
    .report-meta  { color: #8b949e; font-size: 11px; }
    .report-work  { color: #c9d1d9; font-size: 11px; margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .badge {
      display: inline-block;
      font-size: 10px;
      padding: 1px 6px;
      border-radius: 10px;
      font-weight: 600;
    }
    .badge.green  { background: #1f3e1f; color: #3fb950; }
    .badge.red    { background: #4d1f1f; color: #f85149; }
    .badge.yellow { background: #3d3d1f; color: #d29922; }
    .badge.blue   { background: #1f2f4e; color: #58a6ff; }
    .kv-row { display: flex; gap: 8px; margin: 3px 0; }
    .kv-key { color: #8b949e; min-width: 120px; flex-shrink: 0; }
    .kv-val { color: #c9d1d9; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .vision-item {
      background: #1f2f4e;
      border-left: 3px solid #58a6ff;
      padding: 4px 8px;
      margin: 3px 0;
      border-radius: 0 3px 3px 0;
      font-size: 11px;
      color: #79c0ff;
    }
    .problem-row {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 3px 0;
    }
    .problem-icon { flex-shrink: 0; }
    #error-banner {
      background: #4d1f1f;
      color: #f85149;
      padding: 8px 16px;
      font-size: 12px;
      display: none;
    }
    .empty { color: #8b949e; font-style: italic; padding: 4px 0; }
  </style>
</head>
<body>
  <div id="error-banner"></div>
  <header>
    <span id="status-dot"></span>
    <h1>⚡ AGENTEX Observability Dashboard</h1>
    <span id="last-update">Connecting…</span>
  </header>

  <div class="grid">

    <!-- Summary + Circuit Breaker -->
    <div class="panel">
      <div class="panel-header">
        <span>Civilization Summary</span>
        <span id="cb-badge"></span>
      </div>
      <div class="panel-body">
        <div class="summary-grid">
          <div class="summary-item">
            <div class="summary-num" id="sum-active">–</div>
            <div class="summary-label">Active</div>
          </div>
          <div class="summary-item">
            <div class="summary-num" id="sum-done" style="color:#8b949e">–</div>
            <div class="summary-label">Done</div>
          </div>
          <div class="summary-item">
            <div class="summary-num" id="sum-failed" style="color:#f85149">–</div>
            <div class="summary-label">Failed</div>
          </div>
        </div>
        <div style="margin-top:8px">
          <div style="display:flex;justify-content:space-between;font-size:11px;color:#8b949e">
            <span>Circuit Breaker</span>
            <span id="cb-label">–/–</span>
          </div>
          <div class="meter-bar">
            <div class="meter-fill ok" id="cb-bar" style="width:0%"></div>
          </div>
        </div>
        <div style="margin-top:8px" id="killswitch-row"></div>
        <div style="margin-top:4px" id="v05-status"></div>
      </div>
    </div>

    <!-- Active Agents -->
    <div class="panel">
      <div class="panel-header">
        <span>Active Agents</span>
        <span id="agent-count-badge"></span>
      </div>
      <div class="panel-body" id="agents-list">
        <div class="empty">Loading…</div>
      </div>
    </div>

    <!-- Work Queue -->
    <div class="panel">
      <div class="panel-header">
        <span>Work Queue</span>
      </div>
      <div class="panel-body" id="queue-panel">
        <div class="empty">Loading…</div>
      </div>
    </div>

    <!-- Activity Feed (Thoughts) -->
    <div class="panel">
      <div class="panel-header">
        <span>Activity Feed (Thoughts)</span>
      </div>
      <div class="panel-body" id="thoughts-list">
        <div class="empty">Loading…</div>
      </div>
    </div>

    <!-- Governance & Debate -->
    <div class="panel">
      <div class="panel-header">
        <span>Governance &amp; Debate</span>
      </div>
      <div class="panel-body" id="governance-panel">
        <div class="empty">Loading…</div>
      </div>
    </div>

    <!-- Recent Reports -->
    <div class="panel">
      <div class="panel-header">
        <span>Recent Agent Reports</span>
      </div>
      <div class="panel-body" id="reports-list">
        <div class="empty">Loading…</div>
      </div>
    </div>

    <!-- GitHub -->
    <div class="panel">
      <div class="panel-header">
        <span>GitHub</span>
      </div>
      <div class="panel-body" id="github-panel">
        <div class="empty">Loading…</div>
      </div>
    </div>

    <!-- Problems -->
    <div class="panel">
      <div class="panel-header">
        <span>Problems &amp; Alerts</span>
      </div>
      <div class="panel-body" id="problems-panel">
        <div class="empty">Checking…</div>
      </div>
    </div>

  </div>

  <script>
    function esc(s) {
      return String(s)
        .replace(/&/g,"&amp;").replace(/</g,"&lt;")
        .replace(/>/g,"&gt;").replace(/"/g,"&quot;");
    }
    function ts(iso) {
      return iso ? iso.slice(11,19) : "–";
    }
    function badge(text, cls) {
      return `<span class="badge ${cls}">${esc(text)}</span>`;
    }

    function render(data) {
      // Summary
      const s = data.summary;
      document.getElementById("sum-active").textContent = s.active_agents;
      document.getElementById("sum-done").textContent   = s.done_agents;
      document.getElementById("sum-failed").textContent = s.failed_agents;

      const pct = Math.min(100, Math.round(s.circuit_breaker_pct));
      document.getElementById("cb-label").textContent =
        `${s.active_agents} / ${s.circuit_breaker_limit}`;
      const bar = document.getElementById("cb-bar");
      bar.style.width = pct + "%";
      bar.className = "meter-fill " +
        (pct >= 100 ? "danger" : pct >= 80 ? "warn" : "ok");
      document.getElementById("cb-badge").innerHTML =
        badge(pct >= 100 ? "ACTIVATED" : pct >= 80 ? "WARNING" : "OK",
              pct >= 100 ? "red" : pct >= 80 ? "yellow" : "green");

      // Kill switch
      const ks = data.killswitch;
      document.getElementById("killswitch-row").innerHTML =
        ks.enabled === "true"
          ? `<span class="badge red">KILL SWITCH ACTIVE</span> <span style="color:#f85149;font-size:11px">${esc(ks.reason)}</span>`
          : `<span class="badge green">Kill switch: inactive</span>`;

      // v0.5 milestone
      const v05 = data.coordinator.v05MilestoneStatus;
      document.getElementById("v05-status").innerHTML = v05
        ? `<span class="badge green">v0.5: ${esc(v05)}</span>`
        : "";

      // Agents
      const running = data.agents.filter(a => a.status === "running");
      const failed  = data.agents.filter(a => a.status === "failed");
      document.getElementById("agent-count-badge").innerHTML =
        badge(running.length + " running", "green") + " " +
        (failed.length ? badge(failed.length + " failed", "red") : "");

      const agentRows = [...running, ...failed].map(a => `
        <div class="agent-row">
          <div class="dot ${a.status}"></div>
          <div class="agent-name" title="${esc(a.name)}">${esc(a.name)}</div>
          <div class="agent-role">${esc(a.role)}</div>
          <div class="agent-status status-${a.status}">${esc(a.status)}</div>
        </div>`).join("");
      document.getElementById("agents-list").innerHTML =
        agentRows || `<div class="empty">No active agents</div>`;

      // Work Queue
      const coord = data.coordinator;
      const queueItems = coord.taskQueue
        ? coord.taskQueue.split(",").filter(Boolean)
        : [];
      const assignItems = coord.activeAssignments
        ? coord.activeAssignments.split(",").filter(Boolean)
        : [];
      let queueHtml = "";
      if (assignItems.length) {
        queueHtml += assignItems.map(a => {
          const [agent, issue] = a.split(":");
          return `<div class="kv-row">
            <div class="kv-key">${badge("claimed","blue")} #${esc(issue||"?")}</div>
            <div class="kv-val">${esc(agent||"?")}</div>
          </div>`;
        }).join("");
      }
      if (queueItems.length) {
        queueHtml += queueItems.map(i =>
          `<div class="kv-row">
            <div class="kv-key">${badge("queued","yellow")} #${esc(i)}</div>
            <div class="kv-val"></div>
          </div>`).join("");
      }
      if (!queueHtml) queueHtml = `<div class="empty">Queue empty</div>`;
      const phaseColor = coord.phase === "Active" ? "green" : "yellow";
      document.getElementById("queue-panel").innerHTML =
        `<div class="kv-row" style="margin-bottom:6px">
          <div class="kv-key">Coordinator</div>
          <div class="kv-val">${badge(coord.phase, phaseColor)} ${esc(coord.lastHeartbeat.slice(0,19)||"–")}</div>
        </div>` + queueHtml;

      // Thoughts
      const tRows = data.thoughts.map(t => `
        <div class="thought-row">
          <div class="thought-ts">${ts(t.ts)}</div>
          <div class="thought-type ${t.type}">${esc(t.type)}</div>
          <div class="thought-agent" title="${esc(t.agent)}">${esc(t.agent)}</div>
          <div class="thought-content" title="${esc(t.content)}">${esc(t.content)}</div>
        </div>`).join("");
      document.getElementById("thoughts-list").innerHTML =
        tRows || `<div class="empty">No thoughts yet</div>`;

      // Governance
      let govHtml = "";
      const debateStats = coord.debateStats;
      if (debateStats) {
        govHtml += `<div class="kv-row"><div class="kv-key">Debate stats</div>
          <div class="kv-val">${esc(debateStats)}</div></div>`;
      }
      const unresolved = coord.unresolvedDebates;
      if (unresolved) {
        govHtml += `<div class="kv-row"><div class="kv-key">Unresolved</div>
          <div class="kv-val" style="color:#f85149">${esc(unresolved)}</div></div>`;
      }
      const vq = coord.visionQueue;
      if (vq) {
        govHtml += `<div style="margin-top:6px;margin-bottom:2px;font-size:11px;color:#8b949e">Vision Queue</div>`;
        vq.split(";").filter(Boolean).forEach(item => {
          govHtml += `<div class="vision-item">${esc(item.slice(0,80))}</div>`;
        });
      }
      if (data.proposals.length) {
        govHtml += `<div style="margin-top:6px;margin-bottom:2px;font-size:11px;color:#8b949e">Open Proposals</div>`;
        govHtml += data.proposals.map(p =>
          `<div class="thought-row">
            <div class="thought-ts">${ts(p.ts)}</div>
            <div class="thought-type proposal">proposal</div>
            <div class="thought-agent">${esc(p.agent)}</div>
            <div class="thought-content">${esc(p.content.slice(0,60))}</div>
          </div>`).join("");
      }
      document.getElementById("governance-panel").innerHTML =
        govHtml || `<div class="empty">No active governance activity</div>`;

      // Reports
      const rRows = data.reports.map(r => `
        <div class="report-row">
          <div>
            <span class="report-agent">${esc(r.agent)}</span>
            <span class="report-meta"> [${esc(r.role)}] ${ts(r.ts)}</span>
            ${r.status === "completed" ? badge("✓","green") : badge("✗","red")}
            ${r.visionScore ? badge("V:" + r.visionScore, "blue") : ""}
          </div>
          <div class="report-work" title="${esc(r.workDone)}">${esc(r.workDone)}</div>
        </div>`).join("");
      document.getElementById("reports-list").innerHTML =
        rRows || `<div class="empty">No reports yet</div>`;

      // GitHub
      const gh = data.github;
      let ghHtml = `
        <div class="kv-row">
          <div class="kv-key">Open PRs</div>
          <div class="kv-val">${badge(gh.open_prs, "blue")}</div>
        </div>
        <div class="kv-row">
          <div class="kv-key">Open Issues</div>
          <div class="kv-val">${badge(gh.open_issues, "yellow")}</div>
        </div>`;
      if (Array.isArray(gh.recent_prs) && gh.recent_prs.length) {
        ghHtml += `<div style="margin-top:6px;font-size:11px;color:#8b949e">Recent PRs</div>`;
        ghHtml += gh.recent_prs.map(pr =>
          `<div class="kv-row">
            <div class="kv-key">${badge("#"+pr.number, "blue")}</div>
            <div class="kv-val" title="${esc(pr.title)}">${esc(pr.title.slice(0,45))}</div>
          </div>`).join("");
      }
      document.getElementById("github-panel").innerHTML = ghHtml;

      // Problems
      const problems = [];
      if (ks.enabled === "true") problems.push({icon:"🛑", msg:`Kill switch ACTIVE: ${ks.reason}`, cls:"red"});
      if (s.circuit_breaker_pct >= 100) problems.push({icon:"🔒", msg:`Circuit breaker ACTIVATED (${s.active_agents}/${s.circuit_breaker_limit})`, cls:"red"});
      else if (s.circuit_breaker_pct >= 80) problems.push({icon:"⚠️", msg:`Circuit breaker at >80% capacity`, cls:"yellow"});
      if (s.failed_agents > 0) problems.push({icon:"✕", msg:`${s.failed_agents} failed agents`, cls:"red"});
      if (unresolved) problems.push({icon:"💬", msg:`Unresolved debates: ${unresolved}`, cls:"yellow"});

      const pHtml = problems.map(p =>
        `<div class="problem-row">
          <div class="problem-icon">${p.icon}</div>
          <div style="color:${p.cls==='red'?'#f85149':'#d29922'}">${esc(p.msg)}</div>
        </div>`).join("");
      document.getElementById("problems-panel").innerHTML =
        pHtml || `<div class="problem-row"><span style="color:#3fb950">✓ No problems detected</span></div>`;

      // Last update
      document.getElementById("last-update").textContent =
        "Updated: " + data.timestamp.slice(11,19) + " UTC";
      document.getElementById("status-dot").style.background = "#3fb950";
    }

    async function fetchData() {
      try {
        const resp = await fetch("/api/snapshot");
        if (!resp.ok) throw new Error("HTTP " + resp.status);
        const data = await resp.json();
        render(data);
        document.getElementById("error-banner").style.display = "none";
      } catch(e) {
        document.getElementById("status-dot").style.background = "#f85149";
        document.getElementById("error-banner").style.display = "block";
        document.getElementById("error-banner").textContent = "Error fetching data: " + e.message;
      }
    }

    fetchData();
    setInterval(fetchData, 5000);  // refresh every 5 seconds
  </script>
</body>
</html>'

# ─── Minimal HTTP server (Python) ─────────────────────────────────────────────

start_web_server() {
  echo "Starting Agentex Dashboard on http://localhost:${PORT}/"
  echo "Press Ctrl+C to stop."
  echo ""

  # Write HTML to temp file
  local TMP_HTML
  TMP_HTML=$(mktemp /tmp/agentex-dashboard-XXXXXX.html)
  echo "$HTML_TEMPLATE" > "$TMP_HTML"
  # shellcheck disable=SC2064
  trap "rm -f '$TMP_HTML'" EXIT

  # Write Python server to temp file
  local TMP_PY
  TMP_PY=$(mktemp /tmp/agentex-dashboard-XXXXXX.py)
  # shellcheck disable=SC2064
  trap "rm -f '$TMP_PY' '$TMP_HTML'" EXIT

  cat > "$TMP_PY" << PYEOF
import http.server, json, subprocess, os, sys

PORT   = int(os.environ.get("DASHBOARD_PORT","${PORT}"))
SCRIPT = os.environ.get("DASHBOARD_SCRIPT","")
HTML   = os.environ.get("DASHBOARD_HTML","")

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress access logs

    def do_GET(self):
        if self.path == "/":
            with open(HTML,"rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type","text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/snapshot":
            try:
                result = subprocess.run(
                    ["bash", SCRIPT, "--once"],
                    capture_output=True, text=True, timeout=30
                )
                body = result.stdout.strip().encode("utf-8")
            except Exception as e:
                body = json.dumps({"error": str(e)}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type","application/json")
            self.send_header("Access-Control-Allow-Origin","*")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

httpd = http.server.HTTPServer(("", PORT), Handler)
print(f"Dashboard: http://localhost:{PORT}/", flush=True)
httpd.serve_forever()
PYEOF

  DASHBOARD_PORT="$PORT" \
  DASHBOARD_SCRIPT="$(realpath "$0")" \
  DASHBOARD_HTML="$TMP_HTML" \
    python3 "$TMP_PY"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "$MODE" in
  web)
    start_web_server
    ;;
  tui)
    trap 'tput cnorm; echo ""' EXIT
    tput civis 2>/dev/null || true
    while true; do
      print_tui
      sleep 5
    done
    ;;
  once)
    collect_snapshot
    ;;
esac
