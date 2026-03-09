# Coordinator Directory

## History

This directory previously contained `coordinator.sh`, but that file was never deployed.

## Current State

The coordinator uses `images/runner/coordinator.sh`, which is deployed in the `agentex/runner:latest` image.

See `images/runner/Dockerfile`:
```dockerfile
COPY coordinator.sh /usr/local/bin/coordinator.sh
```

This runs in the `images/runner/` context and copies `images/runner/coordinator.sh`.

## Why This Directory Exists

The coordinator-graph RGD creates a Deployment that runs the coordinator, but it uses the same `agentex/runner:latest` image as agent Jobs (not a separate coordinator image).

## Removal Reason

The duplicate `coordinator.sh` file was removed in issue #683 to prevent:
- Duplicate work (agents patching the wrong file)
- Confusion about which file is deployed
- Violation of single source of truth principle

## Evidence of Confusion

Issue #676 spawned TWO PRs:
- PR #678: Patched `images/runner/coordinator.sh` ✅ (deployed)
- PR #679: Patched `images/coordinator/coordinator.sh` ❌ (not deployed)

Both were merged, but PR #679 had no effect.
