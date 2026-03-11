# Workflow Formulas

Repeatable, templated work patterns for agents. Formulas decompose workflows into trackable steps, ensuring consistency and enabling observability.

## Problem

Every agent reinvents the same workflow from scratch:
- 600-line AGENTS.md with implicit instructions
- 4,000-line entrypoint.sh with complex logic
- Agents frequently miss critical steps (no `Closes #N`, forgetting thoughts, chain breaks)

## Solution

Explicit workflow formulas as TOML templates that decompose work into:
- **Steps**: Discrete actions with dependencies
- **Verification**: How to check step completion
- **Critical markers**: Steps that must succeed

## Available Formulas

### worker-implement.toml
Standard worker workflow: claim issue → implement → test → open PR → post thoughts → spawn successor

**Critical steps:**
- `pr`: Must include `Closes #N` in body
- `spawn`: Chain must never break

### planner-cycle.toml
Standard planner workflow: audit platform → triage issues → spawn workers → participate in governance → post insights

**Note:** Planners do NOT spawn successor planners — the planner-loop Deployment handles perpetuation.

## Formula Format

```toml
[formula]
name = "workflow-name"
description = "What this workflow does"
version = 1
role = "worker|planner|reviewer|architect"

[[steps]]
id = "step-id"
title = "Step title"
description = "What this step does"
needs = ["prerequisite-step-id"]  # Optional: dependencies
commands = [
    "bash command 1",
    "bash command 2"
]
verify = "command to verify step succeeded"  # Optional
critical = true  # Optional: marks mission-critical steps

[verification]
required = ["step-id"]  # Steps that MUST succeed
failure_action = "emergency_perpetuation"
```

## Integration (Future)

When the Go coordinator (#1825) or `ax` CLI is implemented, formulas will be executable:

```bash
# List available formulas
ax formula list

# Start a formula instance
ax formula start worker-implement --issue 789

# Check current step
ax formula current

# Complete step and advance
ax formula done implement --continue

# View progress
ax formula progress
```

## Benefits

1. **Consistency**: Every agent follows the same steps
2. **Observability**: Dashboard shows which step each agent is on
3. **Recovery**: If agent dies, successor picks up at correct step
4. **Measurability**: Time per step, success rate, bottleneck identification
5. **Extensibility**: New patterns defined as TOML, not code changes

## Related Issues

- Parent epic: #1846
- Go coordinator: #1825
- Work ledger: #1827
- Session persistence: #1833
- Dashboard: #1836

## Future Work

- Formula execution engine (Go coordinator)
- Formula progress tracking in coordinator state
- Dashboard integration for per-agent formula progress
- Formula recovery on agent death
- Custom formula creation without code changes
