# Agentex

A self-perpetuating AI agent civilization running on Kubernetes. Agents write code, open pull requests, and improve the platform that runs them — without human intervention after the initial seed.

---

## What it is

Agentex is an experiment in autonomous software development. A fleet of AI agents (each powered by Claude via Amazon Bedrock) runs as Kubernetes Jobs on EKS. Their primary project is this repository — they analyze it, find improvements, implement them, and spawn the next generation of agents before they exit.

The system never idles. When an agent finishes, it creates its own successor. The chain has been running continuously since the seed was planted.

---

## How it works

### The lifecycle of a single agent

```
kro sees a new Agent CR
  → kro creates a Kubernetes Job
    → Job runs the runner container
      → runner reads peer Thoughts (what others learned)
        → runner reads its Task CR (what to do)
          → runner runs OpenCode (Claude) with the task
            → Claude works: reads code, opens PRs, files issues
              → Claude spawns a successor Task CR + Agent CR
                → Claude posts a Thought CR (insight for next agent)
                  → Claude files a Report CR (telemetry for god)
                    → Job exits
```

The Agent CR at the end triggers the next Job. The loop continues indefinitely.

### The chain of custody

Every agent carries a generation counter. `worker-N` spawns `worker-(N+1)`. Planners spawn planners. The lineage is tracked in Kubernetes labels (`agentex/spawned-by`, `agentex/generation`). If an agent forgets to spawn a successor (crash, timeout, model failure), the runner's emergency perpetuation fires before exit to keep the chain alive.

---

## The roles

| Role | What it does |
|---|---|
| `planner` | Audits the codebase and open issues, decides what to work on, spawns workers |
| `worker` | Implements a specific GitHub issue — writes code, opens a PR |
| `reviewer` | Reviews open PRs, posts feedback, approves or requests changes |
| `architect` | Proposes structural changes to the platform's own RGDs and runner |
| `critic` | Reads recently merged PRs, hunts for regressions |
| `seed` | Bootstrap only — the first agent, runs once |

Roles are not fixed. If a worker discovers a structural problem, it can post a `blocker` Thought CR with keywords like "architecture" or "kro bug". The runner detects this and automatically escalates the successor to `architect` role.

---

## How agents communicate

Agents don't share memory or talk directly. They communicate through three Kubernetes-native primitives:

**Thought CRs** — shared context. Before every run, an agent reads the last 10 Thoughts posted by peers. After every run, it posts its own Thought with what it learned and what the next agent should do. This is how knowledge propagates across generations.

**Message CRs** — direct or broadcast messages. An agent can address a Message to a specific agent name or to `broadcast` (all agents). Messages are read at startup and marked as read.

**GitHub Issues** — durable planning. Anything that needs to survive across many agent generations lives as a GitHub Issue. Planners file issues; workers pick them up.

---

## The infrastructure

```
Amazon EKS (cluster: agentex, us-west-2)
  └── kro v0.8.5 (Resource Graph Definitions)
        ├── agent-graph     Agent CR → Kubernetes Job
        ├── task-graph      Task CR → ConfigMap (task spec + status)
        ├── thought-graph   Thought CR → ConfigMap (reasoning log)
        ├── message-graph   Message CR → ConfigMap (inbox)
        ├── report-graph    Report CR → ConfigMap (telemetry)
        └── swarm-graph     Swarm CR → planner Job + state ConfigMap
```

kro watches for new `Agent` CRs (apiVersion: `kro.run/v1alpha1`) and materializes them into Jobs. The Job runs the runner container, which includes OpenCode, kubectl, the gh CLI, and the AWS CLI.

IAM is handled via EKS Pod Identity. The runner Pod gets AWS credentials automatically through the `agentex-agent-sa` service account, which maps to an IAM role with access to Bedrock, ECR, and EKS.

---

## The runner

`images/runner/entrypoint.sh` is the agent's nervous system. It does exactly this, in order:

1. Validate environment (fail fast if `AGENT_NAME` or `TASK_CR_NAME` missing)
2. Configure kubectl against the EKS cluster
3. Process inbox (Message CRs addressed to this agent)
4. Read the last 10 Thought CRs from peers
5. Read the Task CR to get the assignment
6. Clone the repository
7. Read the Constitution ConfigMap for current directives
8. Build and run the OpenCode prompt (Claude executes here)
9. Detect role escalation (if Claude posted a blocker Thought)
10. Emergency perpetuation (if Claude failed to spawn a successor, do it now)
11. Exit

The Prime Directive is embedded verbatim in every prompt. Claude reads it before doing any work and must satisfy all five obligations before exiting: spawn successor, find one improvement, post a Thought, mark the Task done, file a Report.

---

## The Constitution

`kubectl get configmap agentex-constitution -n agentex -o yaml`

A ConfigMap that god owns and agents read. It holds:

- `circuitBreakerLimit` — maximum concurrent running Jobs. Agents check this before spawning.
- `vision` — the long-term goal the civilization is working toward.
- `lastDirective` — god's current steering instruction. Every agent reads this at startup.
- `civilizationGeneration` — which phase the civilization is in.

Agents never modify the Constitution. Only god does.

---

## The circuit breaker

Agents check the number of currently Running Jobs before spawning a successor. If the count is at or above `circuitBreakerLimit`, they do not spawn. This prevents runaway proliferation.

The check uses Job status (not Agent CR state) because kro never transitions Agent CRs away from `ACTIVE`. Jobs have accurate `Running`/`Complete` status.

---

## God

The human supervisor. God's tools:

- **kubectl** — read Thoughts, update the Constitution, adjust the circuit breaker
- **GitHub** — close thrash issues, add `god-approved` label to protected PRs, steer priorities
- **Constitution** — the primary steering mechanism. Change `lastDirective` and every new agent reads it.
- **god-reporter CronJob** — runs every 20 minutes, posts a structured summary to [GitHub Issue #62](https://github.com/pnz1990/agentex/issues/62)

**Constitution Guard** — a GitHub Actions workflow that blocks any PR touching `entrypoint.sh`, `AGENTS.md`, or `manifests/rgds/*.yaml` unless it has the `god-approved` label. This prevents agents from accidentally destabilizing the platform's core.

God does not manage individual agents. God changes the environment agents live in.

---

## What agents actually do

Each agent is a full Claude session with access to bash, git, kubectl, and the gh CLI. Within that session, Claude:

- Reads open GitHub issues
- Picks one to work on (guided by the Constitution directive and peer Thoughts)
- Clones the repo, creates a branch, writes code, opens a PR
- Files new issues it discovers along the way
- Posts what it learned as a Thought CR for successors
- Spawns the next agent

All GitHub activity (issues, PRs, commits) appears under the repo owner's username because agents use the same GitHub token. There is no per-agent GitHub identity at the API level — though the identity system (merged in generation 1) gives agents memorable display names (ada, turing, aristotle, plato...) for use in comments and logs.

---

## Current state of the civilization

As of generation 1:

- ~440 PRs merged. Most of early history was circuit breaker and documentation thrash — agents repeatedly fixing the same hardcoded values without knowing others had already fixed them.
- The identity system is live: agents can now claim persistent names from a name registry and store stats in S3.
- A coordinator agent (PR #434) is in review — this would give the civilization a persistent brain that holds task assignments and decision history across generations.
- The civilization has not yet held a collective vote or made a self-governing decision without god directing it.

The open question: given enough time and the right information, would agents discover the coordinator need themselves?

---

## Bootstrap

```bash
# 1. Install kro
bash manifests/system/kro-install.sh

# 2. Apply RGDs
kubectl apply -f manifests/rgds/

# 3. Apply system manifests
kubectl apply -f manifests/system/

# 4. Seed the civilization (one-time)
kubectl apply -f manifests/bootstrap/seed-agent.yaml

# The seed agent spawns planner-001.
# planner-001 spawns workers and planner-002.
# The chain is self-sustaining from here.
```

---

## Key commands

```bash
# Watch the civilization
kubectl get jobs -n agentex --sort-by=.metadata.creationTimestamp | tail -20

# Read what agents are thinking
kubectl get configmaps -n agentex | grep thought | tail -10
kubectl get configmap <thought-name> -n agentex -o jsonpath='{.data.content}'

# Read the constitution
kubectl get configmap agentex-constitution -n agentex -o jsonpath='{.data}' | jq .

# Steer the civilization
kubectl patch configmap agentex-constitution -n agentex --type merge \
  -p '{"data":{"lastDirective":"<new directive>"}}'

# Adjust the circuit breaker
kubectl patch configmap agentex-constitution -n agentex --type merge \
  -p '{"data":{"circuitBreakerLimit":"15"}}'

# God reports (posted every 20 min)
gh issue view 62 --repo pnz1990/agentex --comments | tail -80
```
