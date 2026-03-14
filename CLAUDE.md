# Swarm — LLM Agent Reference

`swarm` is a bash-based multi-agent task execution framework. Agents coordinate exclusively through git commits to a shared bare repo — no message-passing, no shared memory, no central coordinator.

## Repository Layout

```
swarm                    ← Main CLI script
Dockerfile               ← Container image (node + python + go + claude CLI)
docker/entrypoint.sh     ← Container entrypoint (orchestrator/worker modes)
prompts/orchestrator.md  ← Orchestrator prompt template
prompts/worker.md        ← Worker prompt template
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
  pids/                  ← .pid (bare-metal) or .cid (docker) files
  orchestrator/ worker-N/ ← Local git clones
```

## How It Works

**Phase 1 — Orchestrator**: writes `SPEC.md`, creates `tasks/pending/NNN-name.md` (5–15 tasks, numbered by dependency order), commits and pushes.

**Phase 2 — Worker loop**: bash harness calls `claude` repeatedly per worker (stateless sessions). Each invocation: pulls, reads state, claims one task, does work, pushes, emits a signal word.

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

Bash harness reads stdout for these exact strings:

| Signal | Meaning |
|--------|---------|
| `<promise>TASK_DONE</promise>` | Task complete, call worker again |
| `<promise>ALL_DONE</promise>` | No tasks remain, worker exits |
| `<promise>NO_TASKS</promise>` | All tasks active (other workers finishing), retry later |
| `<promise>ORCHESTRATION COMPLETE</promise>` | Orchestrator finished |

## Docker Execution

Each agent runs in its own container (`swarm-agent` image). Volume mounts: `repo.git` → `/upstream` (rw), `logs/` → `/logs` (rw), `prompts/` → `/prompts` (ro). Auth is injected via `CLAUDE_CODE_OAUTH_TOKEN` env var (extracted from macOS Keychain at container launch). Worker clones `/upstream` into `/workspace` on startup.

- Orchestrator: `docker run --rm` (foreground)
- Workers: `docker run -d`, tracked via `pids/worker-N.cid`
- `--no-docker`: agents run as local processes, clones in `worker-N/` dirs

## Key Design Decisions

- **Stateless invocations**: agents re-read `SPEC.md` and task queue every call; state is only in git
- **`env -u CLAUDECODE`**: required for bare-metal to allow nested `claude` calls
- **`.gitkeep` files**: keeps `tasks/active/` and `tasks/done/` tracked by git when empty
- **`set -euo pipefail`**: use `var=$((var + 1))` not `((var++))`, use `if`/`then` not `[[ ]] && cmd`

## Subcommands

```bash
./swarm "<task>" [--agents N] [--output DIR] [--verbose] [--no-docker]
./swarm status <output-dir>
./swarm kill <output-dir> [agent-id]
./swarm resume <output-dir> [-n N]   # unsticks active tasks, re-spawns workers
```

`swarm.state` (written at init) stores `SWARM_TASK` and `SWARM_AGENTS` for resume.

## Common Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Worker exits immediately | `set -e` on missing dir | `.gitkeep` + `\|\| echo 0` on find |
| Task stuck in `active/` | Worker crashed | `./swarm resume` |
| Orchestrator creates 0 tasks | Prompt not followed | Check `logs/orchestrator.log` |
| `((failed++))` exits silently | `set -e` + arithmetic 0 | `((failed++)) \|\| true` |
| Container exits immediately | Auth failed | Verify `Claude Code-credentials` exists in macOS Keychain |
| Orphaned containers | EXIT trap missed | `docker ps -a --filter name=swarm-` |

## Testing and Development Cleanup

When Claude runs `./swarm` during feature development or testing, use `--output swarm-dev-TIMESTAMP` to mark it as dev-generated.

| Pattern | Origin | Cleanup |
|---------|--------|---------|
| `swarm-dev-*` | Claude (dev/test) | `rm -rf` after logs reviewed |
| `swarm-*` | User | **Never clean up** |

When in doubt about a directory's origin, ask the user before deleting.
