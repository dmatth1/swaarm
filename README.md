# swarm

Build software with a team of parallel Claude Code agents coordinating through a shared bare git repo. Give it a task, walk away, come back to finished code.

Inspired by [Anthropic's multi-agent C compiler experiment](https://www.anthropic.com/engineering/building-c-compiler). Same git-based coordination model.

## Requirements

- [Docker](https://docs.docker.com/get-docker/) (agents run in containers by default)
- `git`
- `bash` (macOS or Linux)

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
  • Creates 5–15 numbered task files in tasks/pending/
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
./swarm "<task>" [OPTIONS]

Options:
  -n, --agents N    Number of parallel workers (default: 3)
  -o, --output DIR  Output directory (default: ./swarm-TIMESTAMP)
  -v, --verbose     Stream agent output live to terminal
  -h, --help        Show help
```

```bash
# Check status of a running swarm
./swarm status <output-dir>

# Kill all agents
./swarm kill <output-dir>

# Kill a specific agent
./swarm kill <output-dir> worker-1
./swarm kill <output-dir> orchestrator

# Resume after interruption (rate limit, crash, kill)
./swarm resume <output-dir>
./swarm resume <output-dir> -n 2   # resume with fewer/more workers
```

## Examples

```bash
./swarm "Build a Python CLI that converts CSV to JSON"

./swarm "Build a FastAPI server with CRUD endpoints for a blog (posts, comments, users)" --agents 4

./swarm "Create a Go CLI that watches a directory and auto-compresses new image files"

./swarm "Write a comprehensive pytest test suite for the codebase in /path/to/project" \
  --output ./test-results

./swarm "Build a static site generator that converts Markdown to HTML with Jinja2 templates"
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

```bash
# Live task progress
watch -n 5 'ls swarm-*/main/tasks/done/'

# Follow all agent logs at once
tail -f swarm-*/logs/*.log

# Follow a specific worker
tail -f swarm-*/logs/worker-1.log

# Structured status view
./swarm status ./swarm-20240115-143022
```

## Resuming after interruption

**Rate limits are handled automatically.** Workers detect rate-limit responses from Claude and sleep with exponential backoff (5 min → 15 min → 30 min → 1 hr → 2 hr → 4 hr, ±20% jitter) while keeping their task claimed. When the limit resets, they resume automatically — no intervention needed. Their task stays in `tasks/active/` throughout.

If you want to restart immediately after a rate limit clears rather than waiting for the backoff, use `resume`.

If a run stops mid-way for other reasons (crash, `Ctrl-C`, killed worker), use `resume` to pick up where it left off:

```bash
./swarm resume ./swarm-20240115-143022
```

Resume automatically:
1. Moves any stuck `tasks/active/worker-N--*.md` files back to `tasks/pending/`
2. Commits and pushes the unstick to the shared repo
3. Spawns fresh workers to finish the remaining tasks

You can change the worker count when resuming:

```bash
./swarm resume ./swarm-20240115-143022 -n 5
```

If resume says "Nothing to resume — all tasks already complete", you're done.

If tasks keep getting stuck on resume, check the logs to understand why:

```bash
tail -50 ./swarm-20240115-143022/logs/worker-1.log
```

## Killing agents

```bash
# Kill all running agents
./swarm kill ./swarm-20240115-143022

# Kill just worker-2 (e.g. it's stuck)
./swarm kill ./swarm-20240115-143022 worker-2
```

After killing, run `./swarm resume <dir>` to restart workers on remaining tasks. No manual git manipulation needed.

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
The worker likely crashed mid-task. Check `logs/worker-N.log`, then run `./swarm resume <dir>` — it moves stuck tasks back to pending and restarts workers automatically.

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

Claude Code has a native [agent teams feature](https://docs.claude.ai/en/agent-teams) (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`).

| | swarm | Agent Teams |
|--|--|--|
| Interface | Fire-and-forget CLI | Interactive (lives in your session) |
| Coordination | Bare git repo + file moves | Native task list + mailbox |
| Agent comms | None (git only) | Direct peer-to-peer messaging |
| Visibility | Log files, `status` command | tmux split panes / Shift+Down |
| Human steering | Not needed | Redirect agents mid-task |
| Best for | Automated pipelines, unattended | Interactive development |

Use swarm when you want to hand off a task and walk away. Use Agent Teams when you want to observe and steer.
