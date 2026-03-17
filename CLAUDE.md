# Swarm — LLM Agent Reference

`swarm` is a bash-based multi-agent task execution framework. Agents coordinate exclusively through git commits to a shared bare repo — no message-passing, no shared memory, no central coordinator.

## Repository Layout

```
swarm                    ← Main CLI script
Dockerfile               ← Container image (node + python + go + claude CLI)
docker/entrypoint.sh     ← Container entrypoint (orchestrator/worker modes)
prompts/orchestrator.md  ← Orchestrator prompt template (new + augment modes)
prompts/worker.md        ← Worker prompt template
prompts/reviewer.md      ← Reviewer agent prompt template
prompts/task-format.md   ← Shared task creation guide (appended to all task-creating agents)
BACKLOG.md               ← Known bugs, missing tests, and planned features
```

Output directory created per run:
```
swarm-TIMESTAMP/
  repo.git/              ← Bare git repo (coordination hub)
  main/                  ← Read-only synced clone for observation
    SPEC.md / CLAUDE.md / PROGRESS.md
    tasks/pending|active|done/
    [project files]
  logs/orchestrator.log, worker-N.log
  pids/                  ← .cid files tracking running worker containers
  swarm.state            ← Persists SWARM_TASK and SWARM_AGENTS for resume
```

## How It Works

**Phase 1 — Orchestrator**: writes `SPEC.md`, writes `CLAUDE.md` (living project index for worker orientation), creates `tasks/pending/NNN-name.md` (numbered by dependency order), commits and pushes. Key rules:
- Acceptance criteria must be `Run: <cmd>` → `Expected: <output>` format — no vague criteria
- `## Interfaces` subsections capped at 25 lines (split into `NameCore`/`NameDetails` if larger)
- Mandatory `001-project-setup.md` and final `NNN-testing-and-verification.md`
- Mandatory mid-project checkpoint task for 10+ task projects (~40–60% mark)
- Dependency graph verified before committing: no cycles, no spurious deps, parallelism audited

**Phase 2 — Worker loop**: bash harness calls `claude` repeatedly per worker (stateless sessions). Each invocation: pulls, reads state, claims one task, does work, pushes, emits a signal word.

**Phase 3 — Reviewer loop** (`run_with_review` mode): a lightweight reviewer runs tests after each task completion and signals `TESTS_PASS` or `TESTS_FAIL`. If `TESTS_FAIL`, the orchestrator is triggered immediately to add fix tasks. Periodically (every N completions), the orchestrator also runs in augment mode alongside a specialist sweep to restructure pending tasks, fix stale manifests, and handle blocked tasks. Final drain: when pending and active are empty, a final test review confirms completion.

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
| `<promise>TESTS_PASS</promise>` | Reviewer | Tests passing |
| `<promise>TESTS_FAIL</promise>` | Reviewer | Tests failing, orchestrator triggered |

**Stuck-state detection**: after 3 consecutive idle cycles with pending tasks and no active workers, the harness triggers the orchestrator in augment mode. The orchestrator diagnoses deadlocks (circular dependencies or missing prerequisite tasks) and adds resolution tasks.

## Docker Execution

Each agent runs in its own container (`swarm-agent` image). Volume mounts: `repo.git` → `/upstream` (rw), `logs/` → `/logs` (rw), `prompts/` → `/prompts` (ro). Auth is injected via `CLAUDE_CODE_OAUTH_TOKEN` env var (extracted from macOS Keychain on macOS, or `~/.claude/credentials.json` on Linux).

- Orchestrator: `docker run --rm` (foreground, exits when done)
- Workers: `docker run -d`, tracked via `pids/worker-N.cid`

**Worker container lifecycle**: each worker container is long-lived — it clones `/upstream` into `/workspace` once at startup, then loops: pull → claim task → run claude → complete → repeat. The container persists across multiple tasks. Non-git state (installed packages, build artifacts) accumulates in `/workspace` across tasks on the same worker; this is intentional as later tasks typically depend on setup done by earlier ones. All canonical project state is in git.

**When to rebuild the image**: prompts (`prompts/*.md`) and the `swarm` script are mounted or run on the host — no rebuild needed. **Rebuild when `Dockerfile` or `docker/entrypoint.sh` change**: `docker rmi swarm-agent && ./swarm ...` (auto-rebuilds on next run).

## Key Design Decisions

- **CLAUDE.md as project index**: orchestrator creates it and updates it during periodic augment; workers get it auto-loaded by Claude Code. Kept under 200 lines. Orientation (structure, stack, build commands) lives here; contracts (interfaces, criteria) stay in SPEC.md
- **Stateless invocations**: agents re-read `CLAUDE.md` (auto) + `SPEC.md` and task queue every call; state is only in git
- **`.gitkeep` files**: keeps `tasks/active/` and `tasks/done/` tracked by git when empty
- **`set -euo pipefail`**: use `var=$((var + 1))` not `((var++))`, use `if`/`then` not `[[ ]] && cmd`
- **Rate-limit backoff**: workers detect rate-limit output from claude (429, "too many requests", "quota exceeded", account-level "hit your limit / resets UTC") and sleep with exponential backoff (5m→15m→30m→1hr→2hr→4hr ±20% jitter) without releasing their claimed task; backoff retries don't count against `MAX_WORKER_ITERATIONS`
- **Real-time log streaming**: `run_claude()` pipes claude output through `stream_parse.py` which parses `--output-format stream-json` events — text deltas go to log in real-time, result text goes to `CLAUDE_OUTPUT_FILE` for signal/rate-limit grep; `./swarm logs` wraps `tail -f` for convenience
- **Log rotation**: `truncate_log()` caps log files at `MAX_LOG_SIZE` (default 10MB) after each `run_claude()` call; keeps the tail (most recent output), prepends a marker; disable with `MAX_LOG_SIZE=0`
- **Respawn cap**: dead workers are automatically respawned up to `MAX_RESPAWNS` (default 5) times; counter resets when any task completes; prevents infinite loops on persistent failures (e.g., corrupt repo, disk full)
- **Periodic orchestrator**: every N task completions (default 6, configurable via `RESTRUCTURE_INTERVAL`), the orchestrator runs in augment mode alongside a specialist sweep — reviews/fixes pending tasks, updates CLAUDE.md/SPEC.md, handles BLOCKED tasks, and adds tasks for test failures or gaps. Runs concurrently with workers; git conflicts handled by normal rebase/retry
- **Parallel specialist sweeps**: all specialists in a sweep launch concurrently (background `&` + `wait`); each gets its own container/clone; push conflicts handled by rebase in specialist prompt
- **Remote repo mirroring** (`--repo URL`): local bare repo stays the fast coordination hub; harness pushes to GitHub after each `sync_main`. When set, `PUBLIC_REPO=true` env var triggers a security notice in all agent prompts prohibiting secrets/PII commits

## Subcommands

```bash
./swarm "<prompt>" [-o DIR] [-n N] [--model M] [--repo URL] [--mount HOST:CONTAINER] [--verbose]
# If -o points to existing run → resume (unstick tasks, augment via orchestrator if new guidance, re-spawn workers)
# If -o absent or new dir → new run (orchestrate + workers)
./swarm status <output-dir>
./swarm kill <output-dir> [agent-id]
./swarm logs <output-dir> [worker-N]     # tail agent logs in real-time
./swarm cleanup [output-dir]             # remove orphaned containers
```

`swarm.state` (written at init) stores `SWARM_TASK`, `SWARM_AGENTS`, `SWARM_MODEL`, `SWARM_REPO` for resume.

## Monitoring a Run

```bash
# Progress ticker (done/active/pending counts + key events)
tail -f /tmp/swarm-resume-*.log | grep --line-buffered "Progress\|specialist\|Specialist\|worker\|Worker\|reviewer\|Reviewer\|COMPLETE\|spawning"

# All agent logs unified (orchestrator + workers + specialists + reviewers)
tail -f <output-dir>/logs/orchestrator.log <output-dir>/logs/worker-*.log <output-dir>/logs/specialist-*.log <output-dir>/logs/reviewer-*.log

# Running containers
docker ps --filter "name=swarm-" --format "table {{.Names}}\t{{.Status}}"

# Task state
ls <output-dir>/main/tasks/active/   # currently claimed
ls <output-dir>/main/tasks/pending/  # waiting for workers
ls <output-dir>/main/tasks/done/     # completed
```

## Common Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Worker exits immediately | `set -e` on missing dir | `.gitkeep` + `\|\| echo 0` on find |
| Task stuck in `active/` | Worker crashed | `./swarm -o <dir>` |
| Orchestrator creates 0 tasks | Prompt not followed | Check `logs/orchestrator.log` |
| `((failed++))` exits silently | `set -e` + arithmetic 0 | `((failed++)) \|\| true` |
| Container exits immediately | Auth failed | Verify `Claude Code-credentials` in macOS Keychain or `~/.claude/credentials.json` on Linux |
| Workers sleeping, no progress | Rate limit hit | Automatic — workers back off and retry; or `./swarm -o <dir>` to restart manually |
| Orphaned containers | EXIT trap missed | `docker ps -a --filter name=swarm-` |

## Testing

Run all tests: `bash tests/run_tests.sh` (~34s parallel)

Tests mock the Claude CLI (no API tokens). E2E tests (`test_e2e.sh`) use a mock claude that performs real git operations (claim tasks, create files, push commits). All other tests mock at the harness level (override `docker_run_*` functions via `load_swarm`).

Key test files:
- `test_e2e.sh` — Full lifecycle, crash recovery, resume, specialist sweeps, rate limit, log streaming
- `test_reviewer_loop.sh` — Review loop: TESTS_PASS/TESTS_FAIL signals, stuck detection via orchestrator, blocked task handling, specialist parallel execution
- `test_quiet_periods.sh` — Periodic restructuring: orchestrator triggered at interval, RESTRUCTURE_INTERVAL configurable, TESTS_FAIL triggers orchestrator
- `test_unified_command.sh` — New run vs resume detection, orchestrator augment, state restore

## Development Cleanup

When Claude runs `./swarm` during feature development or testing, use `--output swarm-dev-TIMESTAMP` to mark it as dev-generated.

| Pattern | Origin | Cleanup |
|---------|--------|---------|
| `swarm-dev-*` | Claude (dev/test) | `rm -rf` after logs reviewed |
| `swarm-*` | User | **Never clean up** |

When in doubt about a directory's origin, ask the user before deleting.
