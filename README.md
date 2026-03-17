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
- **Linux**: reads from `~/.claude/credentials.json`

If you haven't authenticated yet, run `claude` once in your terminal and log in. That's it — swarm handles the rest.

The Docker image is built automatically on first run (~2 min). It includes Claude Code CLI, Python, Node.js, Go, and common dev tools.

## Quick start

```bash
chmod +x ./swarm

./swarm "Build a REST API for a todo app with SQLite"
```

Your project lands in `swarm-TIMESTAMP/main/`.

## How it works

```
You: ./swarm "Build a todo REST API" --agents 3
         │
         ▼
  Orchestrator (1 Claude session)
  • Analyzes the task
  • Writes SPEC.md with tech stack, architecture, file layout
  • Creates numbered task files in tasks/pending/ (as many as needed)
  • Commits everything to shared bare git repo
         │
         ▼
  Workers (N parallel Claude sessions)
  Each worker loops:
  1. git pull (see latest state)
  2. Claim a task: mv tasks/pending/NNN-task.md tasks/active/worker-N--NNN-task.md + push
     → git's atomic push is the lock: if two workers race, one push fails, loser picks another task
  3. Do the work, commit as you go
  4. Mark done: mv tasks/active/... tasks/done/NNN-task.md + push
  5. Signal TASK_DONE → shell loop restarts with same prompt for next task
  Until no tasks remain
         │
         ▼
  Your project, complete in main/
```

No message broker. No infrastructure. Just Docker, git, and Claude Code.

## vs. the Anthropic blog post

swarm closely matches Anthropic's original multi-agent architecture:

- Bare git repo as the shared coordination hub
- Each agent runs in its own Docker container with an isolated `/workspace`
- Git's atomic push as the distributed lock (two agents racing to claim the same task: one push wins, the other is rejected and picks a different task)
- Stateless agent invocations (each Claude session starts fresh, reads the repo to find its task)
- Pull → work → commit → push cycle with merge conflict handling

**What swarm adds:** an explicit 3-state task machine (`tasks/pending/` → `tasks/active/` → `tasks/done/`) with numbered files, giving clearer progress visibility than the blog post's `current_tasks/` lock files.

**One difference from the blog post:** swarm workers are long-lived containers — each worker clones the repo once at startup and loops across multiple tasks rather than spawning a fresh container per task. Non-git state (installed packages, build artifacts) persists within a worker's `/workspace` across tasks, which is intentional — a setup task's installed dependencies are available to subsequent tasks on the same worker. All canonical project state lives in git regardless.

## Usage

```bash
./swarm "<prompt>" [OPTIONS]

Options:
  -n, --agents N    Number of parallel workers (default: 3)
  -o, --output DIR  Output directory (new run if absent, resume if exists)
  -v, --verbose     Show agent output in terminal (logs always stream to files)
  --model MODEL     Claude model to use (e.g. opus, sonnet, opus[1m])
  --repo URL        Push to a remote GitHub repo (keeps local coordination fast)
  -h, --help        Show help
```

```bash
# Resume with new guidance — just point -o at an existing run
./swarm "Also add rate limiting" -o ./swarm-20240115-143022
./swarm "Fix the tests" -o ./swarm-20240115-143022 -n 5

# Utility subcommands
./swarm status <output-dir>              # live status
./swarm kill <output-dir> [worker-N]     # stop agents
./swarm logs <output-dir> [worker-N]     # tail logs
./swarm cleanup [output-dir]             # remove orphaned containers
```

## Examples

```bash
# New projects
./swarm "Build a Python CLI that converts CSV to JSON"
./swarm "Build a FastAPI blog server with CRUD" --agents 4
./swarm "Build a real-time chat server" --model opus --repo https://github.com/user/chat

# Resume / add guidance to existing run
./swarm "Also add WebSocket support" -o ./swarm-20240115-143022
./swarm "Fix the failing integration tests" -o ./swarm-20240115-143022 -n 5
```

## Output structure

```
swarm-20240115-143022/
├── main/                    ← YOUR PROJECT IS HERE
│   ├── SPEC.md              ← Full spec written by orchestrator
│   ├── PROGRESS.md          ← Progress log
│   ├── tasks/
│   │   ├── pending/         ← NNN-taskname.md files waiting to be claimed
│   │   ├── active/          ← worker-N--NNN-taskname.md (currently being worked)
│   │   └── done/            ← NNN-taskname.md (completed)
│   └── [your project files] ← The actual code
├── logs/
│   ├── orchestrator.log
│   ├── worker-1.log
│   └── worker-2.log
├── pids/
│   ├── worker-1.cid         ← Docker container ID, cleaned up when worker exits
│   └── worker-2.cid
├── repo.git/                ← Bare git repo (the coordination hub)
└── swarm.state              ← Persists task + agent count for resume
```

## Monitoring

Agent logs stream in real-time — you can watch what each agent's Claude is thinking as it works.

```bash
# Follow all agent logs (real-time)
./swarm logs ./swarm-20240115-143022

# Follow a specific worker
./swarm logs ./swarm-20240115-143022 worker-1

# Live task progress
watch -n 5 'ls swarm-*/main/tasks/done/'

# Structured status view
./swarm status ./swarm-20240115-143022
```

## Resuming and adding guidance

Point `-o` at an existing swarm output directory to resume. You can provide new guidance in the prompt — the inject agent will create additional tasks:

```bash
# Resume after crash/rate-limit
./swarm -o ./swarm-20240115-143022

# Add new features to an existing run
./swarm "Also add rate limiting and an admin dashboard" -o ./swarm-20240115-143022

# Resume with more workers
./swarm "Fix the failing tests" -o ./swarm-20240115-143022 -n 5
```

Resume automatically:
1. Moves any stuck `tasks/active/worker-N--*.md` files back to `tasks/pending/`
2. If the prompt differs from the original task, injects new tasks via the inject agent
3. Spawns fresh workers to finish remaining + new tasks

**Rate limits are handled automatically.** Workers detect rate-limit responses from Claude — both API-level 429 errors and account-level usage caps ("You've hit your limit") — and sleep with exponential backoff (5 min → 15 min → 30 min → 1 hr → 2 hr → 4 hr, ±20% jitter). No intervention needed.

## Pushing to GitHub

Use `--repo` to mirror all progress to a remote GitHub repository:

```bash
./swarm "Build a REST API" --repo https://github.com/user/my-api
```

Workers coordinate through the local bare repo (fast). The harness pushes to GitHub after each status sync. When `--repo` is set, all agents receive a security notice prohibiting commits of API keys, passwords, PII, or other secrets.

## Killing agents

```bash
# Kill all running agents
./swarm kill ./swarm-20240115-143022

# Kill just worker-2 (e.g. it's stuck)
./swarm kill ./swarm-20240115-143022 worker-2
```

After killing, run `./swarm -o <dir>` to restart workers on remaining tasks. No manual git manipulation needed.

## How the git lock works

This is the same coordination mechanism Anthropic used in their 16-agent compiler experiment.

When two workers simultaneously try to claim the same task:

1. Both move `tasks/pending/003-routes.md` → `tasks/active/worker-N--003-routes.md` locally
2. Both push — one succeeds, one gets `rejected (non-fast-forward)`
3. The loser does `git pull`, sees the task is already in `tasks/active/` under a different name, and picks a different task

No lock server needed. Git's atomic push is the lock.

## Choosing agent count

Agent count is a tradeoff between parallelism and coordination overhead. A rough guide:

| Agents | When to use |
|--------|-------------|
| 2 | Tasks with many sequential dependencies |
| 3 (default) | Most tasks |
| 4–5 | Large projects with many independent components |
| 6+ | Very large codebases, explicitly parallel work (e.g. test suites) |

The orchestrator creates tasks with parallelism in mind, but it can't always predict every dependency. More agents doesn't always mean faster completion.

## Troubleshooting

**"No tasks completed. Check logs"**
The orchestrator failed before creating tasks. Check `logs/orchestrator.log`. The task description may be too vague, or Claude Code may not be authenticated.

**Workers finish instantly with no work done**
Previously caused by empty `tasks/active/` and `tasks/done/` dirs not being tracked by git, causing workers to crash on missing paths. Fixed with `.gitkeep` files in bootstrap. If you see this on an older version, update.

**Worker stuck in `tasks/active/` indefinitely**
The worker likely crashed mid-task. Check `logs/worker-N.log`, then run `./swarm -o <dir>` — it moves stuck tasks back to pending and restarts workers automatically.

**"git push rejected"**
This is normal — another worker claimed the same task first. Workers handle this automatically by pulling and picking a different task.

**Merge conflicts**
Also normal. Workers auto-resolve by rebasing.

## Customizing agent behavior

Edit the prompts to change how agents approach tasks:

- `prompts/orchestrator.md` — controls task decomposition: how many tasks, how detailed, what tech stack preferences, naming conventions
- `prompts/worker.md` — controls how workers claim tasks, write code, handle blockers, structure commits

Both files use `{{TASK}}` and `{{AGENT_ID}}` placeholders substituted at runtime. You can specialize these for a domain — e.g., always use TypeScript, always write tests first, always target a specific framework.

## swarm vs Claude Code Agent Teams

Claude Code has a native [agent teams feature](https://code.claude.com/docs/en/agent-teams) (experimental, disabled by default).

| | swarm | Agent Teams |
|--|--|--|
| **Status** | Stable | Experimental (requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) |
| **Interface** | Fire-and-forget CLI | Interactive (lives in your terminal session) |
| **Coordination** | Bare git repo + file moves | Shared task list + mailbox |
| **Agent comms** | None (git only) | Direct peer-to-peer messaging + broadcast |
| **Isolation** | Each agent in its own Docker container | Shared filesystem, no container isolation |
| **Built-in QA** | Reviewer agent runs tests, adds fix tasks automatically | No built-in QA loop — lead coordinates manually |
| **Rate limits** | Automatic exponential backoff (5m → 4hr) | No built-in handling |
| **Resume** | `./swarm -o <dir>` — fully recoverable | `/resume` does not restore teammates |
| **Remote push** | `--repo` mirrors to GitHub automatically | No built-in remote push |
| **Visibility** | Log files, `status` command, `logs` tail | tmux split panes / Shift+Down |
| **Human steering** | Not needed (but `inject` adds guidance mid-run) | Redirect agents mid-task, message teammates directly |
| **Token cost** | Lower (stateless sessions, re-reads git each turn) | Higher (each teammate has persistent full context) |
| **Best for** | Automated pipelines, unattended runs, CI | Interactive development, research, code review |

Use swarm when you want to hand off a task and walk away. Use Agent Teams when you want to observe and steer in real time.

## Contributing

Known bugs, missing tests, and planned features are tracked in [`BACKLOG.md`](BACKLOG.md).
