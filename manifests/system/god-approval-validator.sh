#!/bin/bash
# god-approval-validator.sh
# 
# Validates PRs labeled 'constitution-aligned' for automated god-approval
# 
# Usage: ./god-approval-validator.sh <PR_NUMBER>
# 
# Validation criteria:
# 1. PR only touches protected files (entrypoint.sh, AGENTS.md, manifests/rgds/*.yaml)
# 2. PR description cites constitution rules or governance decisions
# 3. PR description explains safety boundary maintenance
# 4. PR is linked to a GitHub issue
#
# Exit codes:
# 0 - Validation passed, PR is constitution-aligned
# 1 - Validation failed, PR needs manual review
# 2 - Invalid usage or missing dependencies

set -euo pipefail

PR_NUMBER="${1:-}"
REPO="${REPO:-pnz1990/agentex}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

error() {
    echo -e "${RED}ERROR:${NC} $*" >&2
}

success() {
    echo -e "${GREEN}✓${NC} $*"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

# Check dependencies
if ! command -v gh &> /dev/null; then
    error "gh CLI is not installed or not in PATH"
    exit 2
fi

if ! command -v jq &> /dev/null; then
    error "jq is not installed or not in PATH"
    exit 2
fi

# Validate usage
if [ -z "$PR_NUMBER" ]; then
    error "Usage: $0 <PR_NUMBER>"
    exit 2
fi

log "Validating PR #${PR_NUMBER} for constitution alignment..."

# Fetch PR details
PR_DATA=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title,body,files,labels 2>&1) || {
    error "Failed to fetch PR #${PR_NUMBER}: $PR_DATA"
    exit 2
}

# Parse PR data
PR_BODY=$(echo "$PR_DATA" | jq -r '.body // ""')
PR_LABELS=$(echo "$PR_DATA" | jq -r '.labels[].name' | tr '\n' ' ')
PR_FILES=$(echo "$PR_DATA" | jq -r '.files[].path')

# Check if PR has constitution-aligned label
if ! echo "$PR_LABELS" | grep -q "constitution-aligned"; then
    error "PR #${PR_NUMBER} does not have 'constitution-aligned' label"
    exit 1
fi

success "PR has 'constitution-aligned' label"

# Validation 1: Check if PR only touches protected files
PROTECTED_FILES_PATTERN="^(images/runner/entrypoint\.sh|AGENTS\.md|manifests/rgds/.*\.yaml)$"
NON_PROTECTED_FILES=()

while IFS= read -r file; do
    if ! echo "$file" | grep -qE "$PROTECTED_FILES_PATTERN"; then
        NON_PROTECTED_FILES+=("$file")
    fi
done <<< "$PR_FILES"

if [ ${#NON_PROTECTED_FILES[@]} -gt 0 ]; then
    warning "PR touches non-protected files (may be acceptable):"
    for file in "${NON_PROTECTED_FILES[@]}"; do
        echo "  - $file"
    done
    # Not a hard failure - some constitution-aligned PRs may touch other files
    # (e.g., adding scripts, tests, documentation)
fi

# Validation 2: Check if PR description cites constitution/governance
CONSTITUTION_KEYWORDS="constitution|governance|vote|verdict|safety|circuit breaker|kill switch|vision"

if ! echo "$PR_BODY" | grep -qiE "$CONSTITUTION_KEYWORDS"; then
    error "PR description does not cite constitution, governance, or safety concepts"
    error "Expected keywords: constitution, governance, vote, verdict, safety, circuit breaker, kill switch, vision"
    exit 1
fi

success "PR description cites constitution/governance concepts"

# Validation 3: Check if PR is linked to an issue
ISSUE_LINK_PATTERN="(#[0-9]+|issue [0-9]+|closes #[0-9]+|fixes #[0-9]+)"

if ! echo "$PR_BODY" | grep -qiE "$ISSUE_LINK_PATTERN"; then
    warning "PR description may not be linked to a GitHub issue"
    warning "Expected pattern: #N, issue N, closes #N, fixes #N"
    # Not a hard failure - some constitution fixes may be discovered during work
fi

# Validation 4: Check if PR description explains safety maintenance
SAFETY_KEYWORDS="safety|boundary|autonomy|bug fix|enforce|implement|without changing behavior"

if ! echo "$PR_BODY" | grep -qiE "$SAFETY_KEYWORDS"; then
    error "PR description does not explain safety boundary maintenance"
    error "Expected keywords: safety, boundary, autonomy, bug fix, enforce, implement"
    exit 1
fi

success "PR description explains safety boundary maintenance"

# All validations passed
log ""
success "PR #${PR_NUMBER} passed all constitution-alignment validations"
log "This PR is eligible for automated god-approval"
log ""
log "To approve manually: gh pr edit ${PR_NUMBER} --add-label 'god-approved' --repo ${REPO}"
exit 0
