#!/bin/bash
# Security monitoring script for agentex platform
# Run this periodically to check for open security alerts

set -euo pipefail

REPO="${REPO:-pnz1990/agentex}"
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-medium}"

echo "=== Security Alert Check for $REPO ==="
echo "Threshold: $SEVERITY_THRESHOLD and above"
echo ""

# Fetch alerts from GitHub API
ALERTS=$(gh api "/repos/$REPO/code-scanning/alerts" --paginate 2>/dev/null || echo "[]")

# Count by severity
CRITICAL=$(echo "$ALERTS" | jq '[.[] | select(.state=="open" and .rule.security_severity_level=="critical")] | length')
HIGH=$(echo "$ALERTS" | jq '[.[] | select(.state=="open" and .rule.security_severity_level=="high")] | length')
MEDIUM=$(echo "$ALERTS" | jq '[.[] | select(.state=="open" and .rule.security_severity_level=="medium")] | length')
LOW=$(echo "$ALERTS" | jq '[.[] | select(.state=="open" and .rule.security_severity_level=="low")] | length')
TOTAL=$(echo "$ALERTS" | jq '[.[] | select(.state=="open")] | length')

echo "Open Security Alerts:"
echo "  CRITICAL: $CRITICAL"
echo "  HIGH:     $HIGH"
echo "  MEDIUM:   $MEDIUM"
echo "  LOW:      $LOW"
echo "  TOTAL:    $TOTAL"
echo ""

# Show top 5 highest-severity actionable alerts
echo "Top 5 Actionable Alerts:"
echo "$ALERTS" | jq -r '
  [.[] | select(.state=="open" and .rule.security_severity_level != "note")] 
  | sort_by(.rule.security_severity_level) 
  | reverse 
  | .[0:5] 
  | .[] 
  | "  [\(.rule.security_severity_level | ascii_upcase)] \(.rule.id): \(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)"
'

echo ""
echo "View all alerts: https://github.com/$REPO/security/code-scanning"

# Exit with error if critical or high alerts exist
if [ "$CRITICAL" -gt 0 ] || [ "$HIGH" -gt 0 ]; then
  echo ""
  echo "⚠️  WARNING: Critical or High severity alerts detected"
  echo "Action required: Review and remediate high-priority vulnerabilities"
  exit 1
fi

echo "✓ No critical or high severity alerts"
exit 0
