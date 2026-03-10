#!/usr/bin/env bash
# Agent Identity Management
# Persistent identity system for agentex agents
# Source this file from entrypoint.sh at startup

set -euo pipefail

# Global variables exported for use by entrypoint.sh
export AGENT_DISPLAY_NAME=""
export AGENT_IDENTITY_FILE=""

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
      if [[ -n "$AGENT_DISPLAY_NAME" ]]; then
        echo "[identity] Restored identity: $AGENT_DISPLAY_NAME"
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
      save_identity
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
# Stores: {displayName, role, generation, stats}
# Globals:
#   AGENT_NAME, AGENT_DISPLAY_NAME, AGENT_ROLE
#######################################
save_identity() {
  local generation
  generation=$(timeout 10s kubectl get agent.kro.run "$AGENT_NAME" -n agentex \
    -o jsonpath='{.metadata.labels.agentex/generation}' 2>/dev/null || echo "0")
  
  local identity_json
  identity_json=$(cat <<EOF
{
  "agentName": "$AGENT_NAME",
  "displayName": "$AGENT_DISPLAY_NAME",
  "role": "$AGENT_ROLE",
  "generation": $generation,
  "claimedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "stats": {
    "tasksCompleted": 0,
    "issuesFiled": 0,
    "prsMerged": 0,
    "thoughtsPosted": 0
  },
  "specialization": {
    "issueLabels": {},
    "codeAreas": {},
    "debatesWon": 0,
    "synthesisCount": 0
  }
}
EOF
)
  
  local s3_path="s3://${IDENTITY_BUCKET}/${IDENTITY_PREFIX}/${AGENT_NAME}.json"
  
  if echo "$identity_json" | aws s3 cp - "$s3_path" 2>/dev/null; then
    echo "[identity] Saved identity to S3: $s3_path"
    AGENT_IDENTITY_FILE="$s3_path"
  else
    echo "[identity] WARNING: Could not save identity to S3 (bucket may not exist yet)"
    echo "[identity] Identity will not persist across restarts until S3 is configured"
    # Not a fatal error - continue without persistence
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
}

#######################################
# Update identity specialization in S3
# Arguments:
#   $1 - category (issueLabels, codeAreas, debatesWon, synthesisCount)
#   $2 - key (for issueLabels/codeAreas, empty for counters)
#   $3 - increment amount (default: 1)
# Examples:
#   update_specialization "issueLabels" "enhancement" 1
#   update_specialization "codeAreas" "manifests/rgds" 1
#   update_specialization "debatesWon" "" 1
#   update_specialization "synthesisCount" "" 1
#######################################
update_specialization() {
  local category="${1:-}"
  local key="${2:-}"
  local increment="${3:-1}"
  
  if [[ -z "$category" ]]; then
    echo "[identity] ERROR: update_specialization requires category"
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
    echo "[identity] WARNING: Could not read identity from S3 for specialization update"
    return 0
  fi
  
  # Update specialization based on category
  local updated_json
  case "$category" in
    issueLabels|codeAreas)
      # These are objects with keys
      if [[ -z "$key" ]]; then
        echo "[identity] ERROR: $category requires a key"
        return 1
      fi
      updated_json=$(echo "$identity_json" | jq \
        --arg cat "$category" \
        --arg k "$key" \
        --argjson inc "$increment" \
        '.specialization[$cat][$k] = (.specialization[$cat][$k] // 0) + $inc')
      ;;
    debatesWon|synthesisCount)
      # These are simple counters
      updated_json=$(echo "$identity_json" | jq \
        --arg cat "$category" \
        --argjson inc "$increment" \
        '.specialization[$cat] = (.specialization[$cat] // 0) + $inc')
      ;;
    *)
      echo "[identity] ERROR: Unknown specialization category: $category"
      return 1
      ;;
  esac
  
  # Save back to S3
  if echo "$updated_json" | aws s3 cp - "$AGENT_IDENTITY_FILE" 2>/dev/null; then
    echo "[identity] Updated specialization: $category/$key += $increment"
  else
    echo "[identity] WARNING: Could not save updated specialization to S3"
  fi
}

#######################################
# Get top specializations for display in Report CR
# Returns JSON array of top 3 specializations
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
  
  # Extract top 3 specializations
  echo "$identity_json" | jq -c '
    [
      (.specialization.issueLabels // {} | to_entries | map({type: "label", name: .key, count: .value})),
      (.specialization.codeAreas // {} | to_entries | map({type: "codeArea", name: .key, count: .value}))
    ] | flatten | sort_by(-.count) | .[0:3]
  '
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
# Format: "I am Ada (worker-1773006921)"
#######################################
get_identity_signature() {
  local display_name
  display_name=$(get_display_name)
  
  if [[ "$display_name" != "$AGENT_NAME" ]]; then
    echo "I am $display_name ($AGENT_NAME)"
  else
    echo "I am $AGENT_NAME"
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
}

# Auto-initialize if sourced (not if this file is run directly for testing)
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  if [[ -n "${AGENT_NAME:-}" ]] && [[ -n "${AGENT_ROLE:-}" ]]; then
    init_identity
  fi
fi
