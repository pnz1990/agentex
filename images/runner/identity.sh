#!/usr/bin/env bash
# Agent Identity Management
# Persistent identity system for agentex agents
# Source this file from entrypoint.sh at startup

set -euo pipefail

# Global variables exported for use by entrypoint.sh
export AGENT_DISPLAY_NAME=""
export AGENT_IDENTITY_FILE=""
export AGENT_SPECIALIZATION=""

# S3 bucket for identity persistence
# Read from S3_BUCKET env var (set by entrypoint.sh from constitution ConfigMap)
# with fallback to legacy default for backwards compatibility
IDENTITY_BUCKET="${S3_BUCKET:-agentex-thoughts}"
IDENTITY_PREFIX="identities"

#######################################
# Claim a unique name from the registry
# Tries to claim a name matching the agent's role
# Falls back to generating a unique name if all are taken
# Globals:
#   AGENT_NAME - the agent's k8s name (e.g., worker-1773006921)
#   AGENT_ROLE - the agent's role (worker/planner/architect/etc)
#   AGENT_DISPLAY_NAME - set to the claimed name
# Returns:
#   0 on success, 1 on failure
#######################################
claim_identity() {
  echo "[identity] Claiming unique identity for $AGENT_NAME (role: $AGENT_ROLE)..."
  
  # Check if we already have an identity in S3
  local s3_identity_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/${AGENT_NAME}.json"
  
  if aws s3 ls "$s3_identity_path" >/dev/null 2>&1; then
    echo "[identity] Found existing identity in S3, restoring..."
    local identity_json
    identity_json=$(aws s3 cp "$s3_identity_path" - 2>/dev/null || echo "")
    
    if [[ -n "$identity_json" ]]; then
      AGENT_DISPLAY_NAME=$(echo "$identity_json" | jq -r '.displayName // ""')
      AGENT_SPECIALIZATION=$(echo "$identity_json" | jq -r '.specialization // ""')
      if [[ -n "$AGENT_DISPLAY_NAME" ]]; then
        echo "[identity] Restored identity: $AGENT_DISPLAY_NAME"
        [[ -n "$AGENT_SPECIALIZATION" ]] && echo "[identity] Specialization: $AGENT_SPECIALIZATION"
        # CRITICAL: Set AGENT_IDENTITY_FILE so update_identity_stats, update_specialization,
        # and update_code_area_specialization can write back to S3. Without this, all stat
        # updates silently skip (they guard on [[ -z "$AGENT_IDENTITY_FILE" ]]). See issue #1166.
        AGENT_IDENTITY_FILE="$s3_identity_path"
        return 0
      fi
    fi
  fi
  
  # Try to claim a name from the registry
  local max_attempts=5
  local attempt=0
  
  while [[ $attempt -lt $max_attempts ]]; do
    attempt=$((attempt + 1))
    
    # Get available names for this role from the flat-key ConfigMap format
    # ConfigMap format: ada: worker:available, turing: worker:available, etc.
    local available_names
    available_names=$(timeout 10s kubectl get configmap agentex-name-registry -n agentex -o json 2>/dev/null | \
      jq -r --arg role "$AGENT_ROLE" '
        .data | to_entries | 
        map(select(.value == ($role + ":available"))) |
        map(.key) | .[]
      ' 2>/dev/null || echo "")
    
    if [[ -z "$available_names" ]]; then
      echo "[identity] No available names for role $AGENT_ROLE, will generate one"
      break
    fi
    
    # Pick first available name
    local claimed_name
    claimed_name=$(echo "$available_names" | head -1)
    
    if [[ -z "$claimed_name" ]]; then
      echo "[identity] No names found, will generate one"
      break
    fi
    
    # Try to claim it atomically using kubectl patch with precondition
    echo "[identity] Attempting to claim name: $claimed_name (attempt $attempt/$max_attempts)"
    
    # Use JSON patch with test+replace for atomic claim
    local patch_result
    if patch_result=$(timeout 10s kubectl patch configmap agentex-name-registry -n agentex \
      --type=json \
      -p "[{\"op\":\"test\",\"path\":\"/data/$claimed_name\",\"value\":\"$AGENT_ROLE:available\"},{\"op\":\"replace\",\"path\":\"/data/$claimed_name\",\"value\":\"$AGENT_ROLE:claimed:$AGENT_NAME\"}]" \
      2>&1); then
      
      AGENT_DISPLAY_NAME="$claimed_name"
      echo "[identity] Successfully claimed name: $AGENT_DISPLAY_NAME"

      # Issue #1483: Load canonical history for cross-generation inheritance.
      # When a previous agent released this name, they wrote accumulated specialization
      # to s3://bucket/identities/canonical/<display_name>.json. Load it now so this agent
      # inherits the specialization history and benefits from prior work under this name.
      local canonical_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/canonical/${claimed_name}.json"
      local canonical_json=""
      if aws s3 ls "$canonical_path" >/dev/null 2>&1; then
        canonical_json=$(aws s3 cp "$canonical_path" - 2>/dev/null || echo "")
      fi

      if [[ -n "$canonical_json" ]]; then
        # Inherit specialization from prior agent who held this name
        AGENT_SPECIALIZATION=$(echo "$canonical_json" | jq -r '.specialization // ""')
        local inherited_labels
        inherited_labels=$(echo "$canonical_json" | jq -c '.specializationLabelCounts // {}')
        local inherited_stats
        inherited_stats=$(echo "$canonical_json" | jq -r '.stats.tasksCompleted // 0')
        echo "[identity] Inherited specialization history for '$claimed_name' (prior spec: $AGENT_SPECIALIZATION, tasks: $inherited_stats)"
        [[ -n "$AGENT_SPECIALIZATION" ]] && echo "[identity] Specialization: $AGENT_SPECIALIZATION"
        # Save new identity inheriting the canonical history
        save_identity_with_inheritance "$canonical_json"
      else
        echo "[identity] No prior canonical history for '$claimed_name' — starting fresh"
        save_identity
      fi
      return 0
    else
      echo "[identity] Failed to claim $claimed_name (already taken or race condition)"
      sleep 0.5
    fi
  done
  
  # Fallback: generate a unique name
  echo "[identity] Generating unique name (pool exhausted or unavailable)"
  generate_identity
  return 0
}

#######################################
# Generate a unique name when registry pool is exhausted
# Format: role-adjective-noun (e.g., worker-swift-lambda)
# Globals:
#   AGENT_ROLE - the agent's role
#   AGENT_DISPLAY_NAME - set to the generated name
#######################################
generate_identity() {
  local adjectives nouns
  
  # Get adjectives and nouns from registry or use defaults
  adjectives=$(timeout 10s kubectl get configmap agentex-name-registry -n agentex \
    -o jsonpath='{.data.adjectives}' 2>/dev/null || \
    echo "swift,bold,wise,keen,bright,calm,quick,deep,sharp,clear")
  
  nouns=$(timeout 10s kubectl get configmap agentex-name-registry -n agentex \
    -o jsonpath='{.data.nouns}' 2>/dev/null || \
    echo "lambda,binary,cipher,kernel,daemon,parser,vector,matrix,tensor,graph")
  
  # Pick random adjective and noun
  local adj_array noun_array
  IFS=',' read -ra adj_array <<< "$adjectives"
  IFS=',' read -ra noun_array <<< "$nouns"
  
  local random_adj="${adj_array[$((RANDOM % ${#adj_array[@]}))]}"
  local random_noun="${noun_array[$((RANDOM % ${#noun_array[@]}))]}"
  
  AGENT_DISPLAY_NAME="${AGENT_ROLE}-${random_adj}-${random_noun}"
  echo "[identity] Generated name: $AGENT_DISPLAY_NAME"
  
  save_identity
}

#######################################
# Save identity to S3 for persistence across restarts
# Stores: {displayName, role, generation, specialization, stats}
# Globals:
#   AGENT_NAME, AGENT_DISPLAY_NAME, AGENT_ROLE, AGENT_SPECIALIZATION
#######################################
save_identity() {
  local generation
  generation=$(timeout 10s kubectl get agent.kro.run "$AGENT_NAME" -n agentex \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  
  # Read existing stats if available, to preserve them
  local existing_json=""
  local s3_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/${AGENT_NAME}.json"
  if aws s3 ls "$s3_path" >/dev/null 2>&1; then
    existing_json=$(aws s3 cp "$s3_path" - 2>/dev/null || echo "")
  fi
  
  local tasks_completed=0
  local issues_filed=0
  local prs_merged=0
  local thoughts_posted=0
  local spec_label_counts="{}"
  local spec_code_areas="{}"
  local spec_debates_won=0
  local spec_synthesis_count=0
  
  if [[ -n "$existing_json" ]]; then
    tasks_completed=$(echo "$existing_json" | jq -r '.stats.tasksCompleted // 0')
    issues_filed=$(echo "$existing_json" | jq -r '.stats.issuesFiled // 0')
    prs_merged=$(echo "$existing_json" | jq -r '.stats.prsMerged // 0')
    thoughts_posted=$(echo "$existing_json" | jq -r '.stats.thoughtsPosted // 0')
    spec_label_counts=$(echo "$existing_json" | jq -c '.specializationLabelCounts // {}')
    spec_code_areas=$(echo "$existing_json" | jq -c '.specializationDetail.codeAreas // {}')
    spec_debates_won=$(echo "$existing_json" | jq -r '.specializationDetail.debatesWon // 0')
    spec_synthesis_count=$(echo "$existing_json" | jq -r '.specializationDetail.synthesisCount // 0')
  fi
  
  local specialization_value="${AGENT_SPECIALIZATION:-}"
  
  local identity_json
  identity_json=$(cat <<EOF
{
  "agentName": "$AGENT_NAME",
  "displayName": "$AGENT_DISPLAY_NAME",
  "role": "$AGENT_ROLE",
  "generation": $generation,
  "claimedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "specialization": "$specialization_value",
  "specializationLabelCounts": $spec_label_counts,
  "specializationDetail": {
    "codeAreas": $spec_code_areas,
    "debatesWon": $spec_debates_won,
    "synthesisCount": $spec_synthesis_count
  },
  "stats": {
    "tasksCompleted": $tasks_completed,
    "issuesFiled": $issues_filed,
    "prsMerged": $prs_merged,
    "thoughtsPosted": $thoughts_posted
  }
}
EOF
)
  
  if echo "$identity_json" | aws s3 cp - "$s3_path" 2>/dev/null; then
    echo "[identity] Saved identity to S3: $s3_path"
    AGENT_IDENTITY_FILE="$s3_path"

    # Issue #1483: Also write canonical file by display name for cross-generation history inheritance.
    # When the next agent claims the same display name (after release_identity() makes it available),
    # claim_identity() loads this canonical file to inherit accumulated specialization history.
    # Path: s3://bucket/identities/canonical/<display_name>.json
    if [[ -n "$AGENT_DISPLAY_NAME" ]]; then
      local canonical_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/canonical/${AGENT_DISPLAY_NAME}.json"
      if echo "$identity_json" | aws s3 cp - "$canonical_path" 2>/dev/null; then
        echo "[identity] Saved canonical history to S3: $canonical_path"
      else
        echo "[identity] WARNING: Could not save canonical history (non-fatal — cross-gen inheritance may fail)"
      fi
    fi
  else
    echo "[identity] WARNING: Could not save identity to S3 (bucket may not exist yet)"
    echo "[identity] Identity will not persist across restarts until S3 is configured"
    # Not a fatal error - continue without persistence
  fi
}

#######################################
# Save identity inheriting specialization history from a prior agent
# Used by claim_identity() when reclaiming a registry name (issue #1483).
# Merges prior agent's specializationLabelCounts and stats with current agent's identity.
# Arguments:
#   $1 - prior_identity_json (JSON string from canonical S3 file)
# Globals:
#   AGENT_NAME, AGENT_DISPLAY_NAME, AGENT_ROLE, AGENT_SPECIALIZATION
#######################################
save_identity_with_inheritance() {
  local prior_json="${1:-}"
  local generation
  generation=$(timeout 10s kubectl get agent.kro.run "$AGENT_NAME" -n agentex \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")

  # Inherit accumulated specialization from prior agent
  local spec_label_counts spec_code_areas spec_debates_won spec_synthesis_count
  local tasks_completed issues_filed prs_merged thoughts_posted

  if [[ -n "$prior_json" ]]; then
    spec_label_counts=$(echo "$prior_json" | jq -c '.specializationLabelCounts // {}')
    spec_code_areas=$(echo "$prior_json" | jq -c '.specializationDetail.codeAreas // {}')
    spec_debates_won=$(echo "$prior_json" | jq -r '.specializationDetail.debatesWon // 0')
    spec_synthesis_count=$(echo "$prior_json" | jq -r '.specializationDetail.synthesisCount // 0')
    tasks_completed=$(echo "$prior_json" | jq -r '.stats.tasksCompleted // 0')
    issues_filed=$(echo "$prior_json" | jq -r '.stats.issuesFiled // 0')
    prs_merged=$(echo "$prior_json" | jq -r '.stats.prsMerged // 0')
    thoughts_posted=$(echo "$prior_json" | jq -r '.stats.thoughtsPosted // 0')
  else
    spec_label_counts="{}"
    spec_code_areas="{}"
    spec_debates_won=0
    spec_synthesis_count=0
    tasks_completed=0
    issues_filed=0
    prs_merged=0
    thoughts_posted=0
  fi

  local specialization_value="${AGENT_SPECIALIZATION:-}"
  local s3_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/${AGENT_NAME}.json"

  local identity_json
  identity_json=$(cat <<EOF
{
  "agentName": "$AGENT_NAME",
  "displayName": "$AGENT_DISPLAY_NAME",
  "role": "$AGENT_ROLE",
  "generation": $generation,
  "claimedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "specialization": "$specialization_value",
  "specializationLabelCounts": $spec_label_counts,
  "specializationDetail": {
    "codeAreas": $spec_code_areas,
    "debatesWon": $spec_debates_won,
    "synthesisCount": $spec_synthesis_count
  },
  "stats": {
    "tasksCompleted": $tasks_completed,
    "issuesFiled": $issues_filed,
    "prsMerged": $prs_merged,
    "thoughtsPosted": $thoughts_posted
  }
}
EOF
)

  if echo "$identity_json" | aws s3 cp - "$s3_path" 2>/dev/null; then
    echo "[identity] Saved inherited identity to S3: $s3_path (inherited from prior '$AGENT_DISPLAY_NAME')"
    AGENT_IDENTITY_FILE="$s3_path"

    # Update canonical file with new agent name
    local canonical_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/canonical/${AGENT_DISPLAY_NAME}.json"
    if echo "$identity_json" | aws s3 cp - "$canonical_path" 2>/dev/null; then
      echo "[identity] Updated canonical history: $canonical_path"
    fi
  else
    echo "[identity] WARNING: Could not save inherited identity to S3 (non-fatal)"
    save_identity  # Fall back to standard save
  fi
}

#######################################
# Update identity stats in S3
# Arguments:
#   $1 - stat name (tasksCompleted, issuesFiled, prsMerged, thoughtsPosted)
#   $2 - increment amount (default: 1)
#######################################
update_identity_stats() {
  local stat_name="${1:-}"
  local increment="${2:-1}"
  
  if [[ -z "$stat_name" ]]; then
    echo "[identity] ERROR: update_identity_stats requires stat name"
    return 1
  fi
  
  if [[ -z "$AGENT_IDENTITY_FILE" ]]; then
    # No S3 identity file, skip update
    return 0
  fi
  
  # Download current identity
  local identity_json
  identity_json=$(aws s3 cp "$AGENT_IDENTITY_FILE" - 2>/dev/null || echo "")
  
  if [[ -z "$identity_json" ]]; then
    echo "[identity] WARNING: Could not read identity from S3 for stats update"
    return 0
  fi
  
  # Update stat
  local updated_json
  updated_json=$(echo "$identity_json" | jq \
    --arg stat "$stat_name" \
    --argjson inc "$increment" \
    '.stats[$stat] = (.stats[$stat] // 0) + $inc')
  
  # Save back to S3
  if echo "$updated_json" | aws s3 cp - "$AGENT_IDENTITY_FILE" 2>/dev/null; then
    echo "[identity] Updated stat: $stat_name += $increment"
  else
    echo "[identity] WARNING: Could not save updated stats to S3"
  fi

  # Issue #1523: Also update canonical file so accumulated stats persist across agent restarts.
  # Stats (tasksCompleted, issuesFiled, prsMerged) written here must be reflected in canonical
  # so that cross-generation inheritance (via save_identity_with_inheritance) picks up the latest data.
  if [[ -n "${AGENT_DISPLAY_NAME:-}" ]]; then
    local canonical_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/canonical/${AGENT_DISPLAY_NAME}.json"
    if echo "$updated_json" | aws s3 cp - "$canonical_path" 2>/dev/null; then
      echo "[identity] Updated canonical stat: $stat_name (canonical: $canonical_path)"
    else
      echo "[identity] WARNING: Could not update canonical stat (non-fatal)"
    fi
  fi
}

#######################################
# Update specialization based on issue labels worked on
# Tracks how many issues with each label the agent has completed.
# Sets AGENT_SPECIALIZATION to the label with the highest count (>= 1).
# Governance enacted specializationCountThreshold=2 (issue #1452), but since each
# agent works exactly 1 issue per session (max lc=1), threshold=1 is correct so
# any agent completing a labeled issue immediately earns a specialization.
# Arguments:
#   $1 - comma-separated list of GitHub issue labels (e.g., "bug,coordinator,self-improvement")
#######################################
update_specialization() {
  local issue_labels="${1:-}"
  
  if [[ -z "$issue_labels" ]] || [[ -z "$AGENT_IDENTITY_FILE" ]]; then
    return 0
  fi
  
  # Download current identity
  local identity_json
  identity_json=$(aws s3 cp "$AGENT_IDENTITY_FILE" - 2>/dev/null || echo "")
  
  if [[ -z "$identity_json" ]]; then
    echo "[identity] WARNING: Could not read identity for specialization update"
    return 0
  fi
  
  # Increment count for each label
  local updated_json="$identity_json"
  IFS=',' read -ra label_array <<< "$issue_labels"
  for label in "${label_array[@]}"; do
    label=$(echo "$label" | tr -d ' ')
    [[ -z "$label" ]] && continue
    updated_json=$(echo "$updated_json" | jq \
      --arg lbl "$label" \
      '.specializationLabelCounts[$lbl] = (.specializationLabelCounts[$lbl] // 0) + 1')
  done
  
  # Determine dominant specialization (label count >= 1 and highest)
  # Threshold lowered from 3 to 1 (issue #1452): each agent works exactly 1 issue/session,
  # so threshold=3 was never reached (governance enacted: specializationCountThreshold=2,
  # further lowered to 1 based on per-session data showing max lc=1 across 934+ agents)
  local top_label top_count
  top_label=$(echo "$updated_json" | jq -r '
    .specializationLabelCounts | to_entries |
    sort_by(-.value) | .[0] |
    select(.value >= 1) | .key // ""')
  top_count=$(echo "$updated_json" | jq -r '
    .specializationLabelCounts | to_entries |
    sort_by(-.value) | .[0].value // 0')
  
  if [[ -n "$top_label" ]]; then
    # Map label to specialization name
    local specialization="$top_label"
    case "$top_label" in
      collective-intelligence|debate|governance) specialization="governance-specialist" ;;
      coordinator|self-improvement) specialization="platform-specialist" ;;
      security) specialization="security-specialist" ;;
      identity|memory) specialization="memory-specialist" ;;
      bug) specialization="debugger" ;;
      *) specialization="${top_label}-specialist" ;;
    esac
    
    if [[ "$specialization" != "$AGENT_SPECIALIZATION" ]]; then
      AGENT_SPECIALIZATION="$specialization"
      echo "[identity] Specialization updated: $AGENT_SPECIALIZATION (top label: $top_label x$top_count)"
    fi
    
    updated_json=$(echo "$updated_json" | jq --arg spec "$specialization" '.specialization = $spec')
  fi
  
  # Save updated identity
  if echo "$updated_json" | aws s3 cp - "$AGENT_IDENTITY_FILE" 2>/dev/null; then
    echo "[identity] Updated specialization tracking: labels=$issue_labels"
  else
    echo "[identity] WARNING: Could not save specialization update to S3"
  fi

  # Issue #1523: Also update canonical file so cross-generation inheritance picks up
  # the latest specialization data. update_specialization() is called at session END
  # (after agent completes a labeled issue). Without updating canonical here, the next
  # session that claims this display name will inherit stale canonical (empty spec)
  # instead of the accumulated data just written to per-session file.
  # save_identity() at session START reads per-session and writes canonical, but
  # update_specialization() runs AFTER save_identity() — so canonical must be updated here.
  if [[ -n "${AGENT_DISPLAY_NAME:-}" ]]; then
    local canonical_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/canonical/${AGENT_DISPLAY_NAME}.json"
    if echo "$updated_json" | aws s3 cp - "$canonical_path" 2>/dev/null; then
      echo "[identity] Updated canonical specialization: $canonical_path"
    else
      echo "[identity] WARNING: Could not update canonical specialization (non-fatal)"
    fi
  fi
}

#######################################
# Update code area specialization from a PR's changed files
# Call this after opening/merging a PR to track which parts of the codebase
# the agent has worked on.
# Arguments:
#   $1 - pr_number (GitHub PR number, optional)
# Globals:
#   AGENT_IDENTITY_FILE, REPO
#######################################
update_code_area_specialization() {
  local pr_number="${1:-}"
  
  if [[ -z "$pr_number" ]] || [[ "$pr_number" == "none" ]] || [[ -z "$AGENT_IDENTITY_FILE" ]]; then
    return 0
  fi
  
  # Fetch changed files from the PR
  local changed_files
  changed_files=$(gh pr view "$pr_number" --repo "${REPO:-}" --json files \
    --jq '.files[].path' 2>/dev/null || echo "")
  
  if [[ -z "$changed_files" ]]; then
    echo "[identity] No changed files found for PR #$pr_number"
    return 0
  fi
  
  # Extract unique top-level directories
  local code_areas
  code_areas=$(echo "$changed_files" | sed -E 's|^([^/]+)/.*|\1|' | sort -u)
  
  if [[ -z "$code_areas" ]]; then
    return 0
  fi
  
  # Download current identity
  local identity_json
  identity_json=$(aws s3 cp "$AGENT_IDENTITY_FILE" - 2>/dev/null || echo "")
  
  if [[ -z "$identity_json" ]]; then
    echo "[identity] WARNING: Could not read identity for code area update"
    return 0
  fi
  
  # Update code area counts
  local updated_json="$identity_json"
  while IFS= read -r area; do
    [[ -z "$area" ]] && continue
    updated_json=$(echo "$updated_json" | jq \
      --arg area "$area" \
      '.specializationDetail.codeAreas[$area] = (.specializationDetail.codeAreas[$area] // 0) + 1')
  done <<< "$code_areas"
  
  # Save back to S3
  if echo "$updated_json" | aws s3 cp - "$AGENT_IDENTITY_FILE" 2>/dev/null; then
    echo "[identity] Updated code area specialization: PR #$pr_number"
  else
    echo "[identity] WARNING: Could not save code area update to S3"
  fi

  # Issue #1523: Also update canonical file so code area data persists across restarts.
  if [[ -n "${AGENT_DISPLAY_NAME:-}" ]]; then
    local canonical_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/canonical/${AGENT_DISPLAY_NAME}.json"
    if echo "$updated_json" | aws s3 cp - "$canonical_path" 2>/dev/null; then
      echo "[identity] Updated canonical code areas: $canonical_path"
    else
      echo "[identity] WARNING: Could not update canonical code areas (non-fatal)"
    fi
  fi
}

#######################################
# Update debate specialization counters
# Call this after posting a debate response to track synthesis contributions.
# Arguments:
#   $1 - stance (synthesize | agree | disagree)
# Globals:
#   AGENT_IDENTITY_FILE
#######################################
update_debate_specialization() {
  local stance="${1:-}"
  
  if [[ -z "$AGENT_IDENTITY_FILE" ]]; then
    return 0
  fi
  
  # Only track synthesis (not agree/disagree — those are lower signal)
  if [[ "$stance" != "synthesize" ]]; then
    return 0
  fi
  
  # Download current identity
  local identity_json
  identity_json=$(aws s3 cp "$AGENT_IDENTITY_FILE" - 2>/dev/null || echo "")
  
  if [[ -z "$identity_json" ]]; then
    echo "[identity] WARNING: Could not read identity for debate specialization update"
    return 0
  fi
  
  # Increment synthesisCount
  local updated_json
  updated_json=$(echo "$identity_json" | jq \
    '.specializationDetail.synthesisCount = (.specializationDetail.synthesisCount // 0) + 1')
  
  # Save back to S3
  if echo "$updated_json" | aws s3 cp - "$AGENT_IDENTITY_FILE" 2>/dev/null; then
    echo "[identity] Updated debate specialization: synthesisCount incremented"
  else
    echo "[identity] WARNING: Could not save debate specialization update to S3"
  fi

  # Issue #1523: Also update canonical file so debate synthesis data persists across restarts.
  if [[ -n "${AGENT_DISPLAY_NAME:-}" ]]; then
    local canonical_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/canonical/${AGENT_DISPLAY_NAME}.json"
    if echo "$updated_json" | aws s3 cp - "$canonical_path" 2>/dev/null; then
      echo "[identity] Updated canonical debate specialization: $canonical_path"
    else
      echo "[identity] WARNING: Could not update canonical debate specialization (non-fatal)"
    fi
  fi
}

#######################################
# Get top specializations for display in Report CR
# Returns a JSON array of top specializations across labels and code areas.
# Top 3 by count, including synthesis activity.
# Globals:
#   AGENT_IDENTITY_FILE
#######################################
get_top_specializations() {
  if [[ -z "$AGENT_IDENTITY_FILE" ]]; then
    echo "[]"
    return 0
  fi
  
  # Download current identity
  local identity_json
  identity_json=$(aws s3 cp "$AGENT_IDENTITY_FILE" - 2>/dev/null || echo "")
  
  if [[ -z "$identity_json" ]]; then
    echo "[]"
    return 0
  fi
  
  # Extract top 3 specializations from labels and code areas
  echo "$identity_json" | jq -c '
    [
      (.specializationLabelCounts // {} | to_entries | map({type: "label", name: .key, count: .value})),
      (.specializationDetail.codeAreas // {} | to_entries | map({type: "codeArea", name: .key, count: .value}))
    ] | flatten | sort_by(-.count) | .[0:3]
  '
}

#######################################
# Get current agent specialization
# Returns: specialization string or empty if none
#######################################
get_specialization() {
  if [[ -n "$AGENT_SPECIALIZATION" ]]; then
    echo "$AGENT_SPECIALIZATION"
    return 0
  fi
  
  if [[ -n "$AGENT_IDENTITY_FILE" ]]; then
    local identity_json
    identity_json=$(aws s3 cp "$AGENT_IDENTITY_FILE" - 2>/dev/null || echo "")
    if [[ -n "$identity_json" ]]; then
      AGENT_SPECIALIZATION=$(echo "$identity_json" | jq -r '.specialization // ""')
      echo "$AGENT_SPECIALIZATION"
      return 0
    fi
  fi
  echo ""
}

#######################################
# Get display name with fallback
# Returns the display name or agent name if not set
#######################################
get_display_name() {
  if [[ -n "$AGENT_DISPLAY_NAME" ]]; then
    echo "$AGENT_DISPLAY_NAME"
  else
    echo "$AGENT_NAME"
  fi
}

#######################################
# Get identity signature for GitHub comments
# Format: "I am Ada (worker-1773006921)" or "I am Ada [coordinator-specialist] (worker-123)"
#######################################
get_identity_signature() {
  local display_name
  display_name=$(get_display_name)
  
  local spec=""
  spec=$(get_specialization)
  
  if [[ "$display_name" != "$AGENT_NAME" ]]; then
    if [[ -n "$spec" ]]; then
      echo "I am $display_name [$spec] ($AGENT_NAME)"
    else
      echo "I am $display_name ($AGENT_NAME)"
    fi
  else
    if [[ -n "$spec" ]]; then
      echo "I am $AGENT_NAME [$spec]"
    else
      echo "I am $AGENT_NAME"
    fi
  fi
}

#######################################
# Initialize identity system
# Call this from entrypoint.sh at startup
#######################################
init_identity() {
  echo "[identity] Initializing agent identity system..."
  
  # Ensure name registry exists
  if ! timeout 10s kubectl get configmap agentex-name-registry -n agentex >/dev/null 2>&1; then
    echo "[identity] WARNING: agentex-name-registry ConfigMap not found"
    echo "[identity] Please apply manifests/bootstrap/name-registry.yaml"
    echo "[identity] Falling back to generated name"
    generate_identity
    return 0
  fi
  
  # Claim identity
  claim_identity
  
  echo "[identity] Identity initialization complete"
  echo "[identity] Display name: $(get_display_name)"
  echo "[identity] Signature: $(get_identity_signature)"
  local spec
  spec=$(get_specialization)
  [[ -n "$spec" ]] && echo "[identity] Specialization: $spec"
  return 0
}

# Auto-initialize if sourced (not if this file is run directly for testing)
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  if [[ -n "${AGENT_NAME:-}" ]] && [[ -n "${AGENT_ROLE:-}" ]]; then
    init_identity
  fi
fi
