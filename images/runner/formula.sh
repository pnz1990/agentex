#!/usr/bin/env bash
# formula.sh — Sourceable workflow formula library for agentex agents
#
# Issue #1846: Workflow formulas — repeatable, templated work patterns for agents
#
# This file provides formula_* functions that can be sourced directly.
# It delegates to the 'ax' CLI for the actual formula engine logic.
#
# WHY TWO FILES?
# - /usr/local/bin/ax — standalone CLI (call as: ax formula start worker-implement)
# - /agent/formula.sh — sourceable library (source then call: formula_start worker-implement)
#
# Both use the same state file and formula directory.
# Agents can use whichever interface fits their context:
#   - OpenCode bash tool: source /agent/formula.sh && formula_start worker-implement
#   - Direct shell: ax formula start worker-implement
#
# USAGE:
#   source /agent/formula.sh
#   formula_list                         # list available formulas
#   formula_start worker-implement       # start a formula
#   formula_current                      # show current step
#   formula_done claim                   # mark step done, advance
#   formula_skip thought "not blocked"   # skip an optional step
#   formula_progress                     # show progress bar
#   formula_persist                      # save state to S3
#   formula_restore worker-123456        # restore from predecessor

# ── Initialization ─────────────────────────────────────────────────────────────
_AX_BIN="${_AX_BIN:-/usr/local/bin/ax}"
FORMULA_DIR="${AX_FORMULA_DIR:-/agent/formulas}"
FORMULA_STATE_FILE="${AX_STATE_FILE:-/tmp/ax-formula-state.json}"

_formula_lib_log() { echo "[formula] $*" >&2; }

# ── Wrapper functions ──────────────────────────────────────────────────────────

formula_list() {
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula list
  else
    echo "Available formulas in ${FORMULA_DIR}:" >&2
    for f in "${FORMULA_DIR}"/*.toml; do
      [ -f "$f" ] && echo "  $(basename "$f" .toml)" >&2
    done
  fi
}

formula_start() {
  local name="${1:-}"
  [ -z "$name" ] && { _formula_lib_log "Usage: formula_start <formula-name>"; return 1; }
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula start "$name"
  else
    _formula_lib_log "ax binary not found at $_AX_BIN"
    return 1
  fi
}

formula_current() {
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula current
  else
    _formula_lib_log "ax binary not found at $_AX_BIN"
    return 1
  fi
}

formula_done() {
  local step="${1:-}"
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula done "$step"
  else
    _formula_lib_log "ax binary not found at $_AX_BIN"
    return 1
  fi
}

formula_skip() {
  local step="${1:-}"
  local reason="${2:-no reason given}"
  [ -z "$step" ] && { _formula_lib_log "Usage: formula_skip <step-id> [reason]"; return 1; }
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula skip "$step" "$reason"
  else
    _formula_lib_log "ax binary not found at $_AX_BIN"
    return 1
  fi
}

formula_progress() {
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula progress
  else
    if [ -f "$FORMULA_STATE_FILE" ]; then
      jq -r '"Formula: \(.formulaName)\nCurrent: \(.currentStep)\nDone: \(.completedSteps | join(", "))"' \
        "$FORMULA_STATE_FILE" 2>/dev/null || cat "$FORMULA_STATE_FILE"
    else
      _formula_lib_log "No active formula"
      return 1
    fi
  fi
}

formula_status() {
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula status
  else
    [ -f "$FORMULA_STATE_FILE" ] && cat "$FORMULA_STATE_FILE" || { _formula_lib_log "No active formula"; return 1; }
  fi
}

formula_resume() {
  local predecessor="${1:-}"
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula resume "$predecessor"
  else
    _formula_lib_log "ax binary not found at $_AX_BIN"
    return 1
  fi
}

# Persist formula state to S3 for recovery by successors
# (ax handles this automatically on state_write, but this provides an explicit call)
formula_persist() {
  if [ ! -f "$FORMULA_STATE_FILE" ]; then
    _formula_lib_log "No active formula state to persist"
    return 0
  fi
  local s3_bucket
  s3_bucket="${S3_BUCKET:-$(kubectl get configmap agentex-constitution -n "${NAMESPACE:-agentex}" \
    -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo 'agentex-thoughts')}"
  local s3_key="formulas/${AGENT_NAME:-unknown}/state.json"
  aws s3 cp "$FORMULA_STATE_FILE" "s3://${s3_bucket}/${s3_key}" \
    --content-type application/json 2>/dev/null \
    && _formula_lib_log "Formula state persisted to s3://${s3_bucket}/${s3_key}" \
    || _formula_lib_log "WARNING: Failed to persist formula state to S3"
}

# Restore formula state from a predecessor agent
formula_restore() {
  local predecessor="${1:-}"
  [ -z "$predecessor" ] && { _formula_lib_log "Usage: formula_restore <predecessor-agent-name>"; return 1; }
  if [ -x "$_AX_BIN" ]; then
    "$_AX_BIN" formula resume "$predecessor"
  else
    local s3_bucket
    s3_bucket="${S3_BUCKET:-$(kubectl get configmap agentex-constitution -n "${NAMESPACE:-agentex}" \
      -o jsonpath='{.data.s3Bucket}' 2>/dev/null || echo 'agentex-thoughts')}"
    local s3_key="formulas/${predecessor}/state.json"
    if aws s3 cp "s3://${s3_bucket}/${s3_key}" "$FORMULA_STATE_FILE" 2>/dev/null; then
      _formula_lib_log "Restored formula state from predecessor: $predecessor"
      formula_progress
    else
      _formula_lib_log "No formula state found for predecessor: $predecessor"
      return 1
    fi
  fi
}

# Check if a step is done (for conditional logic)
formula_step_done() {
  local step_id="$1"
  [ -f "$FORMULA_STATE_FILE" ] || return 1
  local status
  status=$(jq -r --arg s "$step_id" '.completedSteps | index($s) != null' "$FORMULA_STATE_FILE" 2>/dev/null)
  [ "$status" = "true" ]
}
