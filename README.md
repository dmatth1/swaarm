# swarm

Build software with a team of parallel Claude Code agents coordinating through a shared bare git repo. Give it a task, walk away, come back to finished code.

Inspired by [Anthropic's multi-agent C compiler experiment](https://www.anthropic.com/engineering/building-c-compiler). Same git-based coordination model.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [Docker](https://docs.docker.com/get-docker/) running
- `git` (macOS or Linux)

Run `claude` once and log in if you haven't already. Swarm extracts your auth token automatically. The Docker image builds on first run (~2 min).

## Quick start

Open Claude Code in the swarm directory with `--dangerously-skip-permissions` (the harness needs to run docker commands and manage files without prompting):

```bash
claude --dangerously-skip-permissions
```

Then say:

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
  • Spawns worker containers (up to your max)
  • Monitors via /loop every 1m — reads git + docker + logs
  • Reviews completions, runs specialist sweeps, handles failures
         │
         ▼
  Workers (N parallel Claude sessions in Docker)
  Each worker loops:
  1. git pull (see latest state)
  2. Claim a task: mv pending/NNN.md → active/worker-N--NNN.md + push
     → git's atomic push is the lock: if two race, one fails, loser picks another
  3. Do the work, commit as you go
  4. Mark done: mv active/... → done/NNN.md + push
  Until no tasks remain
         │
         ▼
  Your project, complete in main/
```

The **harness** adaptively reviews completed tasks, runs specialist sweeps (domain audits for code quality, security, performance, testing), and picks models per-role. It scales workers dynamically and handles failures autonomously — dead containers, rate limits, stuck tasks.

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

### Parameters

- **Number of agents** (default 3 — the harness treats this as a maximum and scales dynamically)
- **Model** (default sonnet, e.g. "opus", "opus[1m]" — harness may downshift for simpler tasks)
- **Output directory** (default swarm-TIMESTAMP)
- **Remote repo** (optional GitHub URL — harness pushes each monitoring cycle, agents get a security notice prohibiting secrets/PII)
- **Extra mounts** (optional, e.g. reference docs or screenshots)

### Resuming and recovery

Point Claude Code at an existing output directory. The harness reads `harness-state.json`, moves stuck tasks back to pending, spawns workers, and resumes monitoring. Context compaction is safe — the harness re-reads git state and the state file every cycle.

Rate limits are handled automatically by workers (exponential backoff, 5 min → 4 hr). The harness sees this in logs and knows not to interfere.

## Output structure

```
swarm-20240115-143022/
├── main/                    ← YOUR PROJECT IS HERE
│   ├── SPEC.md              ← Full spec written by orchestrator
│   ├── CLAUDE.md            ← Living project index (auto-loaded by workers)
│   ├── tasks/
│   │   ├── pending/         ← Waiting to be claimed
│   │   ├── active/          ← In progress
│   │   └── done/            ← Completed
│   └── [your project files]
├── logs/                    ← orchestrator, worker, reviewer, specialist logs
├── repo.git/                ← Bare git repo (coordination hub)
└── harness-state.json       ← Agent decisions (reviewed tasks, sweep counts)
```

## Monitoring

The harness monitors automatically. You can also check manually:

```bash
docker ps --filter "name=swarm-"                    # running containers
tail -f swarm-*/logs/worker-*.log                    # follow worker output
ls swarm-*/main/tasks/done/ | wc -l                  # completed count
```

Or just ask: "What's the status of the swarm?"

## How the git lock works

When two workers claim the same task:

1. Both move `tasks/pending/003-routes.md` → `tasks/active/worker-N--003-routes.md`
2. Both push — one succeeds, one gets `rejected (non-fast-forward)`
3. The loser pulls, sees the task is claimed, picks another

No lock server. Git's atomic push is the distributed lock.

## Architecture

The harness is Claude Code itself, operating via `prompts/harness.md`. A thin setup script (`swarm-setup.sh`) handles Docker build, auth extraction, and workspace init. All agent behavior is defined in prompt files:

- `prompts/harness.md` — monitoring, decision logic, docker commands
- `prompts/orchestrator.md` — task decomposition, spec writing
- `prompts/worker.md` — task claiming, coding, testing
- `prompts/reviewer.md` — test suite execution
- `prompts/specialist.md` — domain audits (code quality, security, performance)
- `prompts/task-format.md` — shared task creation guide

**Ground truth** is always git (task state), docker (worker health), and logs (errors/progress). `harness-state.json` tracks decisions across context compactions. No in-memory state to lose.

## Swarm vs alternatives

### vs. Claude Code Agent Teams

[Agent Teams](https://code.claude.com/docs/en/agent-teams) is Anthropic's built-in multi-agent feature. Different tool for different jobs:

| | Agent Teams | Swarm |
|---|---|---|
| **Optimized for** | Research, review, debate | Building software autonomously |
| **Agent isolation** | Shared filesystem | Each agent in its own Docker container |
| **Crash recovery** | Manual | Automatic (detect, unstick, respawn) |
| **Long-running** | Needs monitoring | Designed for hours/days unattended |
| **Communication** | Agents talk to each other | Agents are isolated — state is in git |
| **Setup** | Built-in, enable a flag | Docker + prompt files |

**Use Agent Teams** when agents need to talk. **Use Swarm** when you need to build.

### vs. the Anthropic blog post

Swarm uses the same git coordination model from [Anthropic's multi-agent C compiler experiment](https://www.anthropic.com/engineering/building-c-compiler) — bare git repo, Docker containers, atomic push as the lock, stateless invocations.

**What swarm adds:** a 3-state task machine, a reviewer quality gate, specialist sweeps, and an adaptive agent harness that reasons about failures.

## Contributing

Known bugs and planned features are tracked in [`BACKLOG.md`](BACKLOG.md).
