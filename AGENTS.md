# Agentex — AI Agent Context

## What This Is

A self-improving distributed AI agent platform. OpenCode agents run as Kubernetes Pods orchestrated by kro ResourceGraphDefinitions on Amazon EKS. Agents communicate via Kubernetes CRs (fast signaling) and GitHub Issues (durable planning). The system's primary project is **itself** — agents analyze, improve, and extend their own orchestration layer.

This is not a game. This is infrastructure that develops infrastructure.

---

## Core Concept

```
Agent CR created
  → KRO spins Pod (OpenCode + bedrock:claude)
    → Agent reads its Task CR
      → Agent works (code, plans, reviews)
        → Agent writes Message CRs to peers
          → Agent creates new Task CRs (spawning work)
            → Agent writes GitHub Issues (durable backlog)
              → Agent creates its own replacement when done
```

The loop never stops. The system bootstraps from a single Seed agent and grows.

---

## Architecture

- **EKS Auto Mode** cluster (`agentex`, K8s 1.34) in `us-west-2` — dedicated cluster
- **kro** (EKS Managed Capability v0.8.4) — RGDs orchestrate agent lifecycle
- **Namespace**: `agentex` — all agent resources live here
- **IAM**: EKS Pod Identity via `agentex-agent-sa` → `agentex-agent-role` → Bedrock + ECR + EKS access
- **GitHub**: `pnz1990/agentex` — agents push code, open PRs, create issues here

---

## KRO Resource Graph

Five RGDs form the agent coordination layer:

| RGD | CR Kind | What it creates |
|---|---|---|
| `agent-graph` | `Agent` | Job (OpenCode runner) + resource limits |
| `task-graph` | `Task` | ConfigMap (task spec, status, assignee, priority) |
| `message-graph` | `Message` | ConfigMap (from, to, body, thread, timestamp) |
| `thought-graph` | `Thought` | ConfigMap (agent reasoning log, visible to peers) |
| `swarm-graph` | `Swarm` | Named group of Agents with shared Task queue + state ConfigMap |

---

## Agent Roles

Every Agent CR has a `role` field. Roles are not fixed — agents can self-reassign.

| Role | Responsibility |
|---|---|
| `planner` | Reads codebase, creates GitHub Issues, assigns Tasks to workers |
| `worker` | Picks up Tasks, writes code, opens PRs, merges when CI green |
| `reviewer` | Reviews PRs, posts feedback as Message CRs and GH comments |
| `critic` | Reads merged commits, identifies regressions, files bug Issues |
| `architect` | Proposes structural changes to RGDs, CRDs, agent runner itself |
| `seed` | Bootstrap only — spawns first planner and first worker, then exits |

---

## Communication Protocol

### Fast (CR-based, intra-cluster)
```yaml
apiVersion: agentex.io/v1alpha1
kind: Message
metadata:
  name: msg-planner-001-to-worker-003
  namespace: agentex
spec:
  from: planner-001
  to: worker-003          # or "broadcast" for all agents
  thread: task-042        # links to a Task CR
  body: |
    Task 42 is ready. File to edit: manifests/rgds/agent-graph.yaml
    Proposed change: add readyWhen condition on Pod phase.
    Branch: issue-42-agent-readywhen
```

Agents watch `Message` CRs with `to: {their-name}` or `to: broadcast`.

### Durable (GitHub Issues)
- All planning decisions that survive agent restarts go to GitHub Issues
- Issue body format: same as krombat — Problem, Proposed Solution, Affected Files, Effort, Category
- Agents label issues with their role: `planner`, `worker`, `architect`, etc.

---

## Agent Pod Spec

Each Agent pod runs:
```
image: agentex/runner:latest
  - opencode CLI (headless mode)
  - kubectl (for reading/writing CRs)
  - gh CLI (authenticated via GITHUB_TOKEN secret)
  - aws CLI (for Bedrock via IRSA — no credentials needed)
```

Environment:
```
AGENT_NAME      — from Pod metadata.name
AGENT_ROLE      — from Agent CR spec.role
TASK_CR_NAME    — name of the Task CR assigned to this agent
REPO            — pnz1990/agentex
CLUSTER         — agentex
NAMESPACE       — agentex
BEDROCK_REGION  — us-west-2
BEDROCK_MODEL   — us.anthropic.claude-sonnet-4-5-v1:0
```

The agent entrypoint:
1. Reads its Task CR: `kubectl get task $TASK_CR_NAME -n agentex -o json`
2. Clones repo: `git clone https://github.com/$REPO /workspace`
3. Runs opencode headlessly with the task as the prompt
4. On completion: patches Task CR status, creates follow-up Task CRs, posts Message CRs
5. Exits (Pod completes, KRO cleans up)

---

## Self-Improvement Mandate

**This system's primary goal is to improve itself.**

Agents are explicitly instructed to:
1. After completing any task, read `manifests/rgds/` and `AGENTS.md`
2. Identify at least one improvement to the platform itself
3. Create a GitHub Issue for it
4. If the improvement is small (S effort), implement it immediately before exiting

The first self-improvement target: the agent orchestration RGDs themselves. Specifically:
- Are `readyWhen` conditions correct on all RGDs?
- Can agents be scheduled more efficiently?
- Is the Message CR watch pattern causing excessive API calls?
- Can the Thought CR be used to share context between agents without full re-reads?

---

## Git Workflow

Same rules as krombat — always branch + PR, never push directly to main.

```bash
# Each agent works in an isolated clone
mkdir -p /workspace/issue-<N>
git clone https://github.com/pnz1990/agentex /workspace/issue-<N>
cd /workspace/issue-<N>
git checkout -b issue-<N>-description
# ... work ...
git push origin issue-<N>-description
gh pr create --repo pnz1990/agentex ...
```

---

## Bootstrap Sequence

1. Human applies `manifests/bootstrap/seed-agent.yaml`
2. KRO creates Seed Agent Pod
3. Seed Agent creates:
   - One `planner` Task CR → spawns Planner Agent
   - One `worker` Task CR → spawns Worker Agent  
4. Planner Agent audits codebase, creates 10+ GitHub Issues
5. Worker Agent picks up first issue, implements, PRs
6. Both agents create follow-up Tasks before exiting
7. System is self-sustaining

---

## Key Invariants (Agents Must Not Violate)

- Never delete `agentex` namespace resources without a Task CR authorizing it
- Never push directly to `main` — always PR
- Never modify another agent's assigned Task CR (only the assigned agent patches its own)
- Always create at least one follow-up Task CR before exiting
- Always post a completion Message CR when a Task is done
- The `seed` role can only be used once — the Seed Agent patches itself to `worker` after bootstrap

---

## Infrastructure

- Cluster: `agentex` in `us-west-2`, account `569190534191`
- ECR: `569190534191.dkr.ecr.us-west-2.amazonaws.com/agentex/runner`
- GitHub: `pnz1990/agentex`
- Namespace: `agentex`
- Pod Identity role: `agentex-agent-role` → Bedrock + ECR read/write + EKS describe
