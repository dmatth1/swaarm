# Swarm — Multi-Agent Task Execution Framework

`swarm` is a multi-agent task execution framework. Agents (orchestrator, workers, reviewers, specialists) run in Docker containers and coordinate exclusively through git commits to a shared bare repo.

**If the user asks you to run a swarm**, read `prompts/harness.md` for your operating instructions.

## Repository Layout

```
swarm-setup.sh           ← Workspace init, Docker build, auth extraction
Dockerfile               ← Container image (node + python + go + claude CLI + sudo)
docker/entrypoint.sh     ← Container entrypoint (orchestrator/worker/reviewer/specialist)
docker/stream_parse.py   ← Parses stream-json from claude CLI into log + output file
prompts/harness.md       ← Agent harness operating instructions (monitoring, decisions, docker commands)
prompts/orchestrator.md  ← Orchestrator prompt template (new + augment modes)
prompts/worker.md        ← Worker prompt template
prompts/reviewer.md      ← Reviewer agent prompt template
prompts/specialist.md    ← Specialist prompt template (audit-only, creates tasks)
prompts/task-format.md   ← Shared task creation guide (appended to all task-creating agents)
BACKLOG.md               ← Known bugs, missing tests, and planned features
```

Output directory per run:
```
<output-dir>/
  repo.git/              ← Bare git repo (coordination hub)
  main/                  ← Synced clone for observation
    SPEC.md / CLAUDE.md / PROGRESS.md
    tasks/pending|active|done/
    [project files]
  logs/                  ← orchestrator.log, worker-N.log, reviewer-N.log, specialist-*.log
  harness-state.json     ← Agent decisions (reviewed tasks, sweep counts, adaptive decisions)
```

## How It Works

**Phase 1 — Orchestrator**: writes `SPEC.md`, `CLAUDE.md`, creates `tasks/pending/NNN-name.md`, commits and pushes.

**Phase 2 — Workers**: long-lived Docker containers that loop: pull → claim task → run claude → complete → repeat. Each worker is stateless per Claude invocation. Git is the coordination mechanism.

**Phase 3 — Monitoring**: Claude Code (you) monitors via `/loop`, checking `docker ps` + git task state every 1m. Reviews completions, runs specialist sweeps periodically, handles failures adaptively.

**Task state machine**: `pending/NNN-task.md` → `active/worker-N--NNN-task.md` → `done/NNN-task.md`

**Git as distributed lock**: two workers racing to claim the same task both push; one is rejected (non-fast-forward). The loser pulls and picks a different task.

## Worker Protocol

1. `git pull origin main`
2. Read `SPEC.md`, then `ls tasks/pending/`
3. Pick lowest-numbered task whose dependencies are done
4. Claim: `mv tasks/pending/NNN.md tasks/active/AGENT_ID--NNN.md && git add -A && git commit && git push`
5. If push rejected: `git pull --rebase`, pick different task
6. Do the work; commit incrementally
7. Complete: `mv tasks/active/AGENT_ID--NNN.md tasks/done/NNN.md && git add -A && git commit && git push`
8. Emit signal word

## Signal Words

| Signal | Emitted by | Meaning |
|--------|-----------|---------|
| `TASK_DONE` | Worker | Task complete, loop continues |
| `ALL_DONE` | Worker | No tasks remain |
| `NO_TASKS` | Worker | All tasks claimed by others |
| `ORCHESTRATION COMPLETE` | Orchestrator | Tasks created |
| `TESTS_PASS` | Reviewer | Tests passing |
| `TESTS_FAIL` | Reviewer | Tests failing |
| `SPECIALIST_DONE` | Specialist | Audit complete |

## Docker Execution

Each agent runs in its own container (`swarm-agent` image). Volume mounts: `repo.git` → `/upstream` (rw), `logs/` → `/logs` (rw), `prompts/` → `/prompts` (ro). Auth via `CLAUDE_CODE_OAUTH_TOKEN` env var.

- Orchestrator: `docker run --rm` (foreground)
- Workers: `docker run -d --rm` (background, auto-removed on exit)
- Reviewers: `docker run --rm` (foreground)
- Specialists: `docker run --rm` (foreground, parallel except ProjectManager last)

Workers have passwordless sudo — they can `sudo apt-get install` packages as needed.

**Rebuild image when `Dockerfile` or `docker/entrypoint.sh` change**: `docker rmi swarm-agent` (auto-rebuilds on next `swarm-setup.sh`).

## Key Design Decisions

- **Agent harness**: Claude Code manages the run via `/loop` — reads git + docker + logs each cycle, makes adaptive decisions. No bash state machine. See `prompts/harness.md`.
- **Ground truth is git + docker + logs**: task state from `tasks/*/`, worker health from `docker ps`, problems from `tail` of agent logs. `harness-state.json` tracks decisions across context compactions.
- **Adaptive reviews**: harness decides when to run reviewers based on resource pressure, pass/fail track record, and task criticality. Final drain always runs a full test suite.
- **Per-role model selection**: harness can use different models per agent type and task complexity. User's model is the ceiling — harness can downshift for simple work.
- **Dynamic worker count**: user's requested count is a maximum. Harness scales workers to match available parallelism, rate-limit pressure, and remaining task dependencies.
- **`EXTRA_GUIDANCE` env var**: harness injects situational context into any agent's prompt without modifying base prompt files. Used for failure recovery hints, focus areas, prior error context.
- **Stateless worker invocations**: each `claude` call re-reads everything from git. State is only in the repo.
- **Rate-limit backoff**: workers detect 429/"too many requests" and sleep with exponential backoff (5m→4hr ±20% jitter)
- **Invocation timeout**: `run_claude()` wraps `claude` with `timeout $CLAUDE_TIMEOUT` (default 30m). Kills hung invocations.
- **Log rotation**: caps log files at 10MB, keeps the tail
- **Specialists audit-only**: create tasks, don't write code. ProjectManager runs last to consolidate.
- **Remote repo mirroring**: harness pushes to GitHub each cycle. `PUBLIC_REPO=true` triggers security notice.

## Common Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Task stuck in `active/` | Worker died | Move back to `pending/`, respawn |
| Orchestrator creates 0 tasks | Prompt not followed | Check `logs/orchestrator.log` |
| Container exits immediately | Auth failed | Check OAuth token extraction |
| Workers sleeping, no progress | Rate limit | Automatic backoff; or switch model |
| OOM on builds | Docker memory limit | Reduce workers or increase `--memory` |

## Development Cleanup

| Pattern | Origin | Cleanup |
|---------|--------|---------|
| `swarm-dev-*` | Claude (dev/test) | `rm -rf` after review |
| `swarm-*` | User | **Never clean up** |

When in doubt about a directory's origin, ask the user before deleting.
