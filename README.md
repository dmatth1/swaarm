# swarm

Build software with a team of parallel Claude Code agents coordinating through a shared bare git repo. Give it a task, walk away, come back to finished code.

Inspired by [Anthropic's multi-agent C compiler experiment](https://www.anthropic.com/engineering/building-c-compiler). Same git-based coordination model.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [Docker](https://docs.docker.com/get-docker/) running
- `git` (macOS or Linux)

Run `claude` once and log in if you haven't already. Swarm extracts your auth token automatically. The Docker image builds on first run (~2 min).

## Quick start

```bash
claude --dangerously-skip-permissions
```

Then say:

```
"Run swarm for a REST API todo app with SQLite, 3 agents"
```

Claude Code reads the harness instructions, sets up the workspace, spawns the orchestrator and workers, and monitors the run. Your project lands in a `swarm-TIMESTAMP/main/` directory.

## How it works

```
You: "Run swarm for a todo REST API with 3 agents"
         │
         ▼
  Claude Code (harness)
  • swarm-setup.sh → Docker image, auth, workspace, build cache
  • Orchestrator container → SPEC.md + task files
  • Specialist sweep → validates the plan
  • Worker containers (up to your max)
  • Monitors via /loop every 5m — git + docker + logs
         │
         ▼
  Workers (parallel Claude sessions in Docker)
  1. git pull → claim a task → do the work → mark done → repeat
  Git's atomic push is the lock — two workers racing, one wins, loser picks another
         │
         ▼
  Your project, complete in main/
```

The harness reviews tasks adaptively, runs specialist sweeps, scales workers dynamically, picks models per-role, and handles failures autonomously.

No message broker. No infrastructure. Just Docker, git, and Claude Code.

## Usage

Talk to Claude Code naturally:

```
"Run swarm to build a FastAPI blog server, 4 agents, push to github.com/user/blog"
"Resume the swarm in swarm-20240115-143022 with 3 agents"
"Also add rate limiting — run the orchestrator to create new tasks"
"What's the swarm status?"
"Kill the swarm"
"Run a specialist sweep on the current swarm"
```

### Parameters

- **Number of agents** (default 3 — harness scales dynamically, this is a maximum)
- **Model** (default sonnet, e.g. "opus", "opus[1m]" — harness may downshift for simpler tasks)
- **Output directory** (default swarm-TIMESTAMP)
- **Remote repo** (optional GitHub URL — mirror loop syncs every 30s)
- **Extra mounts** (optional, e.g. reference docs)

### Resuming

Point Claude Code at an existing output directory. Setup auto-detects the resume, returns stuck tasks to pending, and spawns workers. The harness re-reads `harness-state.json` every cycle — no conversation history needed.

Rate limits are handled automatically by workers (exponential backoff, 5 min → 4 hr).

## Output structure

```
swarm-TIMESTAMP/
├── main/                    ← YOUR PROJECT
│   ├── SPEC.md              ← Spec written by orchestrator
│   ├── CLAUDE.md            ← Project index (auto-loaded by workers)
│   ├── tasks/
│   │   ├── pending/         ← Waiting to be claimed
│   │   ├── active/          ← In progress
│   │   └── done/            ← Completed
│   ├── harness-state.json   ← Harness decisions, phase, learnings
│   └── [project files]
├── logs/                    ← All agent logs
├── build-cache/             ← Shared ccache across containers
└── repo.git/                ← Bare git repo (coordination hub)
```

## Monitoring

The harness monitors automatically via `/loop`. You can also check:

```bash
docker ps --filter "name=swarm-"              # containers
tail -f swarm-*/logs/worker-*.log              # worker output
ls swarm-*/main/tasks/done/ | wc -l            # completed count
```

Or just ask: "What's the swarm status?"

## How the git lock works

When two workers claim the same task:

1. Both move `tasks/pending/003.md` → `tasks/active/worker-N--003.md`
2. Both push — one succeeds, one gets `rejected (non-fast-forward)`
3. The loser pulls, sees it's claimed, picks another

No lock server. Git's atomic push is the distributed lock.

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

Issues and ideas are tracked in [`BACKLOG.md`](BACKLOG.md).
