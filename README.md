# swarm

Build software with a team of parallel Claude Code agents coordinating through a shared bare git repo. Give it a task, walk away, come back to finished code.

Inspired by [Anthropic's multi-agent C compiler experiment](https://www.anthropic.com/engineering/building-c-compiler). Same git-based coordination model.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated (`claude` CLI must work)
- [Docker](https://docs.docker.com/get-docker/) running
- `git` and `bash` (macOS or Linux)

### Auth setup

swarm runs Claude Code inside Docker containers. It extracts your auth token automatically:

- **macOS**: reads from the `Claude Code-credentials` Keychain entry (created when you run `claude` and log in)
- **Linux**: reads from `~/.claude/.credentials.json` (or `~/.claude/credentials.json`)

If you haven't authenticated yet, run `claude` once in your terminal and log in. That's it — swarm handles the rest.

The Docker image is built automatically on first run (~2 min). It includes Claude Code CLI, Python, Node.js, Go, and common dev tools.

## Quick start

Open Claude Code in the swarm directory and say:

```
"Run swarm for a REST API todo app with SQLite, 3 agents"
```

Claude Code reads the harness instructions, sets up the workspace, spawns the orchestrator and workers, and monitors the run — all conversationally. Your project lands in a `swarm-TIMESTAMP/main/` directory.

## How it works

```
You: "Run swarm for a todo REST API with 3 agents"
         │
         ▼
  Claude Code (harness)
  • Runs swarm-setup.sh (Docker image, auth, workspace init)
  • Spawns orchestrator container → creates SPEC.md + task files
  • Spawns 3 worker containers
  • Monitors via /loop every 1m — reads git + docker + logs
  • Reviews completions, runs specialist sweeps, handles failures
         │
         ▼
  Workers (N parallel Claude sessions in Docker)
  Each worker loops:
  1. git pull (see latest state)
  2. Claim a task: mv tasks/pending/NNN.md → tasks/active/worker-N--NNN.md + push
     → git's atomic push is the lock: if two race, one fails, loser picks another
  3. Do the work, commit as you go
  4. Mark done: mv tasks/active/... → tasks/done/NNN.md + push
  Until no tasks remain
         │
         ▼
  Your project, complete in main/
```

Between workers and completion, the **harness agent** adaptively reviews tasks (deciding when based on resource pressure and pass/fail history), runs specialist sweeps when the project warrants it, and picks models per-role. ProjectManager runs last to consolidate specialist findings.

No message broker. No infrastructure. Just Docker, git, and Claude Code.

## Usage

Talk to Claude Code naturally:

```
# New run
"Run swarm to build a FastAPI blog server, 4 agents, push to github.com/user/blog"

# Resume existing run
"Resume the swarm in swarm-20240115-143022 with 3 agents"

# Add guidance mid-run
"Also add rate limiting — run the orchestrator to create new tasks"

# Check status
"What's the swarm status?"

# Kill a run
"Kill the swarm"

# Run specialists
"Run a specialist sweep on the current swarm"
```

The harness reads `prompts/harness.md` for operating instructions and manages everything via Docker containers and git.

### Parameters

When starting a run, you can specify:
- **Number of agents** (default 3 — this is a maximum; the harness scales dynamically based on available parallelism)
- **Model** (default sonnet, e.g. "opus", "opus[1m]", "haiku" — harness may downshift for simpler tasks)
- **Output directory** (default swarm-TIMESTAMP)
- **Remote repo** (optional GitHub URL for mirroring)
- **Extra mounts** (optional, e.g. reference docs)

## Output structure

```
swarm-20240115-143022/
├── main/                    ← YOUR PROJECT IS HERE
│   ├── SPEC.md              ← Full spec written by orchestrator
│   ├── CLAUDE.md            ← Living project index (auto-loaded by workers)
│   ├── PROGRESS.md          ← Progress log
│   ├── tasks/
│   │   ├── pending/         ← NNN-taskname.md waiting to be claimed
│   │   ├── active/          ← worker-N--NNN-taskname.md in progress
│   │   └── done/            ← NNN-taskname.md completed
│   └── [your project files]
├── logs/
│   ├── orchestrator.log
│   ├── worker-1.log
│   ├── reviewer-N.log
│   └── specialist-*.log
├── repo.git/                ← Bare git repo (coordination hub)
└── harness-state.json       ← Agent decisions (reviewed tasks, sweep counts)
```

## Monitoring

The harness agent monitors automatically via `/loop`. You can also check manually:

```bash
# Running containers
docker ps --filter "name=swarm-"

# Follow worker logs
tail -f swarm-*/logs/worker-*.log

# Task progress
ls swarm-*/main/tasks/done/ | wc -l   # completed
ls swarm-*/main/tasks/pending/ | wc -l # remaining
```

Or just ask Claude Code: "What's the status of the swarm?"

## Resuming

Point Claude Code at an existing output directory to resume. The harness:
1. Reads `harness-state.json` to know what's been reviewed and decided
2. Moves stuck `tasks/active/` files back to `pending/`
3. Spawns fresh workers on remaining tasks
4. Resumes the monitoring loop

Context compaction is safe — the harness re-reads git state and the state file every cycle.

**Rate limits are handled automatically.** Workers detect rate-limit responses and sleep with exponential backoff (5 min → 4 hr, ±20% jitter).

## Pushing to GitHub

Specify a remote repo URL and the harness pushes after each monitoring cycle:

```
"Run swarm for X, push to github.com/user/my-api"
```

Workers coordinate through the local bare repo (fast). When a remote is set, all agents receive a security notice prohibiting secrets/PII.

## How the git lock works

Same coordination as Anthropic's 16-agent compiler experiment. When two workers claim the same task:

1. Both move `tasks/pending/003-routes.md` → `tasks/active/worker-N--003-routes.md`
2. Both push — one succeeds, one gets `rejected (non-fast-forward)`
3. The loser pulls, sees the task is claimed, picks another

No lock server. Git's atomic push is the lock.

## Swarm vs Claude Code Agent Teams

[Agent Teams](https://code.claude.com/docs/en/agent-teams) is Anthropic's built-in multi-agent feature where Claude Code sessions message each other, debate, and collaborate. Swarm takes a different approach — fully isolated Docker containers coordinating through git.

They solve different problems:

| | Agent Teams | Swarm |
|---|---|---|
| **Optimized for** | Research, review, debate | Building software autonomously |
| **Coordination** | Shared task list + direct messaging | Git commits to bare repo |
| **Agent isolation** | Shared filesystem (must avoid file conflicts) | Each agent in its own Docker container |
| **Crash recovery** | Manual (teammates may stop on errors) | Automatic (detect dead containers, unstick tasks, respawn) |
| **Rate limits** | No built-in handling | Exponential backoff, keep task claimed |
| **Quality gates** | Manual (prompt teammates to test) | Adaptive reviewer + final drain full test suite |
| **Long-running** | "Letting a team run unattended increases risk" | Designed for hours/days unattended |
| **Session resume** | Broken (teammates lost on `/resume`) | Works (harness re-reads git + state file) |
| **Communication** | Agents talk to each other | Agents are fully isolated — state is in git |
| **Setup** | Built-in, enable a flag | Docker + setup script + prompt files |

**Use Agent Teams** when agents need to talk — competing hypotheses, multi-angle code review, research synthesis.

**Use Swarm** when you need to build — structured task decomposition, crash recovery, quality gates, overnight autonomy.

## vs. the Anthropic blog post

Swarm's git coordination model comes directly from [Anthropic's multi-agent C compiler experiment](https://www.anthropic.com/engineering/building-c-compiler):

- Bare git repo as the shared coordination hub
- Each agent in its own Docker container with isolated `/workspace`
- Git's atomic push as the distributed lock
- Stateless agent invocations (each Claude session reads the repo fresh)

**What swarm adds:** a 3-state task machine (`pending/` → `active/` → `done/`), a reviewer quality gate, specialist sweeps, and an adaptive agent harness that can reason about failures.

## Customizing agent behavior

Edit the prompts to change how agents approach tasks:

- `prompts/orchestrator.md` — task decomposition, tech stack, naming
- `prompts/worker.md` — how workers claim tasks, write code, handle blockers
- `prompts/reviewer.md` — test validation, artifact checks
- `prompts/specialist.md` — specialist audit behavior (audit-only, create tasks)
- `prompts/task-format.md` — shared task creation guide
- `prompts/harness.md` — harness monitoring and decision logic

## Architecture

The harness is Claude Code itself, operating via instructions in `prompts/harness.md`. A thin setup script (`swarm-setup.sh`) handles deterministic plumbing (Docker build, auth extraction, workspace init).

**Ground truth** is always:
- **Git** for task state (`tasks/pending/`, `tasks/active/`, `tasks/done/`)
- **Docker** for worker health (`docker ps`)
- **`harness-state.json`** for agent decisions (what's been reviewed, when sweeps ran)

The harness re-reads all three sources every monitoring cycle. No in-memory state to lose.

## Running on EC2

For large projects (C++ builds, 5+ workers), a local machine may not have enough RAM. An EC2 `r6i.2xlarge` (64GB, 8 vCPUs, ~$0.15/hr spot) runs swarm comfortably:

```bash
# Ubuntu 22.04 instance
sudo apt-get install -y docker.io tmux git
curl -fsSL https://claude.ai/install.sh | bash
git clone https://github.com/your/swarm-fork.git ~/swarm

# Use tmux so the session survives SSH disconnect
tmux new -s swarm
cd ~/swarm
claude --dangerously-skip-permissions
# Detach: Ctrl+B, D
# Reconnect: tmux attach -t swarm
```

Docker on Linux uses all available RAM by default — no cap like Docker Desktop on Mac.

## Contributing

Known bugs and planned features are tracked in [`BACKLOG.md`](BACKLOG.md).
