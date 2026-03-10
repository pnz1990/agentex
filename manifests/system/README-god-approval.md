# God-Approval Workflow

This directory contains tools for managing the god-approval workflow for protected file changes.

## Protected Files

The following files require the `god-approved` label on PRs:
- `images/runner/entrypoint.sh`
- `AGENTS.md`
- `manifests/rgds/*.yaml`

## Agent Workflow

When you create a PR that touches protected files:

1. **Add the `constitution-aligned` label**:
   ```bash
   gh pr edit <PR_NUMBER> --add-label "constitution-aligned" --repo pnz1990/agentex
   ```

2. **In your PR description, include**:
   - Citation of relevant constitution/vision sections
   - Explanation of why this maintains safety boundaries
   - Link to the GitHub issue or governance vote

3. **Comment on the PR**:
   ```
   Ready for god review - constitution alignment verified
   ```

4. **Continue with other work** — Don't block waiting for approval

## God Workflow

To validate a constitution-aligned PR:

```bash
./manifests/system/god-approval-validator.sh <PR_NUMBER>
```

If validation passes:
```bash
gh pr edit <PR_NUMBER> --add-label "god-approved" --repo pnz1990/agentex
```

## Validation Criteria

The validator checks:
1. ✅ PR primarily touches protected files
2. ✅ PR description cites constitution/governance/safety concepts
3. ✅ PR description explains safety boundary maintenance
4. ⚠️  PR is linked to a GitHub issue (warning only)

## Future Automation

This validator script can be integrated into:
- A CronJob that runs every 15 minutes
- GitHub Actions workflow triggered by label addition
- Coordinator governance decision engine

For now, it provides a manual tool to speed up god review.

## Examples

### Valid Constitution-Aligned PR

**Title**: Fix circuit breaker check in emergency perpetuation

**Body**:
```
Fixes #338 - Circuit breaker proliferation

This PR enforces constitution rule (line 20): "circuitBreakerLimit — max concurrent active jobs. Do not hardcode this value anywhere."

Changes:
- Modified entrypoint.sh emergency perpetuation to check circuit breaker before spawning
- Reads limit from constitution ConfigMap (not hardcoded)

Safety maintenance:
- Does not expand agent autonomy
- Enforces existing safety mechanism
- Bug fix without changing behavior

Ready for god review - constitution alignment verified
```

**Labels**: `constitution-aligned`

### Invalid PR (Expands Autonomy)

**Title**: Allow agents to modify constitution ConfigMap

**Body**:
```
This PR adds a new function to allow agents to update constitution values directly.
```

**Result**: Would be rejected - expands agent autonomy beyond current constitution
