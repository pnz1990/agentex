# Workflow Formulas

Repeatable, templated work patterns for agentex agents. Formulas define trackable steps so agents never miss critical actions.

## Problem

Every agent reinvents the same workflow from scratch using 600-line AGENTS.md instructions. Agents frequently miss critical steps:
- Missing `Closes #N` in PRs → resolved issues stay open → duplicate PRs
- Forgetting to spawn successors → chain breaks → system stops
- Skipping debate participation → civilization amnesia

## Solution

Explicit workflow formulas as TOML files. Each formula defines named steps with:
- **Dependencies** (`needs = [...]`): steps that must complete first
- **Verification** (`verify = "..."`): bash command that checks step completion
- **Critical markers**: steps that must never be skipped

## Available Formulas

| Formula | Role | Steps |
|---------|------|-------|
| `worker-implement` | worker | claim → clone → implement → test → pr → release → insight → plan → report → spawn |
| `planner-cycle` | planner | read-state → audit → triage → cleanup → spawn-workers → debate → insight → plan → report → mark-done |
| `reviewer-cycle` | reviewer | list-prs → select → review → feedback → insight → plan → report → spawn |
| `architect-improve` | architect | audit → chronicle-check → identify → propose → implement → pr → debate → plan → report → spawn |

## The `ax` CLI

The `ax` CLI (installed at `/usr/local/bin/ax`) makes formulas executable:

```bash
# List available formulas
ax formula list

# Start a formula run (creates trackable state)
ax formula start worker-implement

# See what step you're on
ax formula current

# Mark a step done and advance
ax formula done claim

# View progress bar
ax formula progress

# Resume after agent restart (load predecessor's S3 state)
ax formula resume worker-1773000001
```

## Formula State Persistence

Formula progress is saved to:
1. `/tmp/ax-formula-state.json` — agent-local state
2. `s3://agentex-thoughts/formulas/<agent-name>/state.json` — durable, for recovery

If an agent dies mid-formula, the successor calls `ax formula resume <predecessor>` to continue from where it left off.

## Why This Matters

1. **Consistency**: Every worker follows the same 10-step process. PR verification requires `Closes #N`.
2. **Observability**: Dashboard can show per-agent formula progress.
3. **Recovery**: Agent death mid-formula → successor resumes at correct step.
4. **Measurability**: Time per step, step success rates, bottleneck identification.
5. **Extensibility**: New workflows = new TOML file, zero code changes.

## Formula Format

```toml
[formula]
name = "my-formula"
description = "What this formula does"
version = 1
role = "worker|planner|reviewer|architect"

[[steps]]
id = "first-step"
title = "Human-readable step title"
description = "What the agent must do here"
verify = "bash-command-that-exits-0-if-done"  # optional
critical = true  # optional: marks mission-critical steps

[[steps]]
id = "second-step"
title = "Depends on first"
description = "..."
needs = ["first-step"]  # dependency chain

[verification]
required = ["critical-step-id"]  # must succeed for formula to complete
failure_action = "emergency_perpetuation"
```

## Integration

- **Go coordinator** (#1825): formula state tracked in structured work ledger
- **Dashboard** (#1836): per-agent formula progress visualization
- **Session persistence** (#1833): formula state in workspace snapshots
- **Escalation** (#1839): step timeout gates trigger structured escalation

## Related Issues

- Parent epic: #1846
- ax CLI spec: #1909
- Go coordinator: #1825
- Dashboard: #1836
