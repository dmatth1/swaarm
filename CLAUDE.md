# Swarm — LLM Agent Reference

`swarm` is a bash-based multi-agent task execution framework. Agents coordinate exclusively through git commits to a shared bare repo — no message-passing, no shared memory, no central coordinator.

## Repository Layout

```
swarm                    ← Main CLI script
Dockerfile               ← Container image (node + python + go + claude CLI)
docker/entrypoint.sh     ← Container entrypoint (orchestrator/worker modes)
prompts/orchestrator.md  ← Orchestrator prompt template
prompts/worker.md        ← Worker prompt template
prompts/reviewer.md      ← Reviewer agent prompt template
BACKLOG.md               ← Known bugs, missing tests, and planned features
```

Output directory created per run:
```
swarm-TIMESTAMP/
  repo.git/              ← Bare git repo (coordination hub)
  main/                  ← Read-only synced clone for observation
    SPEC.md / PROGRESS.md
    tasks/pending|active|done/
    [project files]
  logs/orchestrator.log, worker-N.log
  pids/                  ← .cid files tracking running worker containers
  swarm.state            ← Persists SWARM_TASK and SWARM_AGENTS for resume
```

## How It Works

**Phase 1 — Orchestrator**: writes `SPEC.md`, creates `tasks/pending/NNN-name.md` (numbered by dependency order), commits and pushes. Key rules:
- Acceptance criteria must be `Run: <cmd>` → `Expected: <output>` format — no vague criteria
- `## Interfaces` subsections capped at 25 lines (split into `NameCore`/`NameDetails` if larger)
- Mandatory `001-project-setup.md` and final `NNN-testing-and-verification.md`
- Mandatory mid-project checkpoint task for 10+ task projects (~40–60% mark)
- Dependency graph verified before committing: no cycles, no spurious deps, parallelism audited

**Phase 2 — Worker loop**: bash harness calls `claude` repeatedly per worker (stateless sessions). Each invocation: pulls, reads state, claims one task, does work, pushes, emits a signal word.

**Phase 3 — Reviewer loop** (`run_with_review` mode): a reviewer agent runs after task completions, checks implementation against SPEC.md interfaces, runs the test suite (Python/Node/Go auto-detected), and adds fix tasks if tests fail. Signals `ALL_COMPLETE` only when pending is empty, active is empty, and tests pass.

**Task state machine**: `pending/NNN-task.md` → `active/worker-N--NNN-task.md` → `done/NNN-task.md`

**Git as distributed lock**: two workers racing to claim the same task both push; one is rejected (non-fast-forward). The loser pulls and picks a different task. No lock server needed.

## Worker Protocol

1. `git pull origin main`
2. Read `SPEC.md`, then `ls tasks/pending/`
3. Pick lowest-numbered task whose dependencies are done
4. Claim: `mv tasks/pending/NNN.md tasks/active/AGENT_ID--NNN.md && git add -A && git commit && git push`
5. If push rejected: `git pull --rebase`, pick different task
6. Do the work; commit incrementally
7. Complete: `mv tasks/active/AGENT_ID--NNN.md tasks/done/NNN.md && git add -A && git commit && git push`
8. Emit signal word (see below)

## Signal Words

| Signal | Emitted by | Meaning |
|--------|-----------|---------|
| `<promise>TASK_DONE</promise>` | Worker | Task complete, call worker again |
| `<promise>ALL_DONE</promise>` | Worker | No tasks remain, worker exits |
| `<promise>NO_TASKS</promise>` | Worker | All tasks active, retry later |
| `<promise>ORCHESTRATION COMPLETE</promise>` | Orchestrator | Task files created |
| `<promise>REVIEW_DONE</promise>` | Reviewer | Reviewed, work continues |
| `<promise>ALL_COMPLETE</promise>` | Reviewer | Project done, tests passing |
| `<promise>INJECTION COMPLETE</promise>` | Inject agent | New tasks created and pushed |

**Stuck-state detection**: after 3 consecutive idle cycles with pending tasks and no active workers, the harness fires the reviewer with `--stuck--`. The reviewer diagnoses the deadlock (circular dependencies or missing prerequisite tasks) and adds resolution tasks.

## Docker Execution

Each agent runs in its own container (`swarm-agent` image). Volume mounts: `repo.git` → `/upstream` (rw), `logs/` → `/logs` (rw), `prompts/` → `/prompts` (ro). Auth is injected via `CLAUDE_CODE_OAUTH_TOKEN` env var (extracted from macOS Keychain on macOS, or `~/.claude/credentials.json` on Linux).

- Orchestrator: `docker run --rm` (foreground, exits when done)
- Workers: `docker run -d`, tracked via `pids/worker-N.cid`

**Worker container lifecycle**: each worker container is long-lived — it clones `/upstream` into `/workspace` once at startup, then loops: pull → claim task → run claude → complete → repeat. The container persists across multiple tasks. Non-git state (installed packages, build artifacts) accumulates in `/workspace` across tasks on the same worker; this is intentional as later tasks typically depend on setup done by earlier ones. All canonical project state is in git.

## Key Design Decisions

- **Stateless invocations**: agents re-read `SPEC.md` and task queue every call; state is only in git
- **`.gitkeep` files**: keeps `tasks/active/` and `tasks/done/` tracked by git when empty
- **`set -euo pipefail`**: use `var=$((var + 1))` not `((var++))`, use `if`/`then` not `[[ ]] && cmd`
- **Rate-limit backoff**: workers detect rate-limit output from claude and sleep with exponential backoff (5m→15m→30m→1hr→2hr→4hr ±20% jitter) without releasing their claimed task; backoff retries don't count against `MAX_WORKER_ITERATIONS`

## Subcommands

```bash
./swarm "<task>" [--agents N] [--output DIR] [--verbose]
./swarm status <output-dir>
./swarm kill <output-dir> [agent-id]
./swarm resume <output-dir> [-n N]   # unsticks active tasks, re-spawns workers
./swarm inject <output-dir> "<guidance>"  # add tasks to existing run
```

`swarm.state` (written at init) stores `SWARM_TASK` and `SWARM_AGENTS` for resume.

## Common Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Worker exits immediately | `set -e` on missing dir | `.gitkeep` + `\|\| echo 0` on find |
| Task stuck in `active/` | Worker crashed | `./swarm resume` |
| Orchestrator creates 0 tasks | Prompt not followed | Check `logs/orchestrator.log` |
| `((failed++))` exits silently | `set -e` + arithmetic 0 | `((failed++)) \|\| true` |
| Container exits immediately | Auth failed | Verify `Claude Code-credentials` in macOS Keychain or `~/.claude/credentials.json` on Linux |
| Workers sleeping, no progress | Rate limit hit | Automatic — workers back off and retry; or `./swarm resume` to restart manually |
| Orphaned containers | EXIT trap missed | `docker ps -a --filter name=swarm-` |

## Testing and Development Cleanup

When Claude runs `./swarm` during feature development or testing, use `--output swarm-dev-TIMESTAMP` to mark it as dev-generated.

| Pattern | Origin | Cleanup |
|---------|--------|---------|
| `swarm-dev-*` | Claude (dev/test) | `rm -rf` after logs reviewed |
| `swarm-*` | User | **Never clean up** |

When in doubt about a directory's origin, ask the user before deleting.
