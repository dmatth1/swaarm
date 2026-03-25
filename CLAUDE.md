# Swarm — Multi-Agent Task Execution Framework

Agents (orchestrator, workers, reviewers, specialists) run in Docker containers and coordinate through git commits to a shared bare repo.

**To run a swarm**, read `prompts/harness.md` for operating instructions.

## Repository Layout

```
swarm-setup.sh           ← Workspace init, Docker build, auth, remote config (one command)
Dockerfile               ← Container image (node + python + go + cmake + ccache + xvfb + claude CLI)
docker/entrypoint.sh     ← Container entrypoint (all roles)
docker/stream_parse.py   ← Parses stream-json from claude CLI into log + output file
prompts/harness.md       ← Harness operating instructions (setup, monitoring, decisions, docker commands)
prompts/orchestrator.md  ← Orchestrator prompt (task decomposition, spec writing)
prompts/worker.md        ← Worker prompt (task claiming, coding, testing)
prompts/reviewer.md      ← Reviewer prompt (test execution)
prompts/specialist.md    ← Specialist prompt (domain audits, task creation)
prompts/task-format.md   ← Shared task creation guide
```

## How It Works

1. **Orchestrator** writes `SPEC.md`, creates `tasks/pending/NNN-name.md`, commits and pushes.
2. **Workers** loop in Docker containers: pull → claim task → do work → complete → repeat. Stateless per invocation.
3. **Harness** (Claude Code) monitors via `/loop 5m` — reads git + docker + logs, reviews completions, runs specialist sweeps, handles failures adaptively.

Task state machine: `pending/` → `active/` → `done/`. Git's atomic push is the distributed lock.

## Key Architecture

- **Ground truth**: git (task state) + docker (container health) + harness-state.json (decisions, phase, reviewed tasks)
- **Remote mirroring**: background mirror loop pushes to GitHub every 30s
- **Build cache**: shared volume mounted on all containers, ccache pre-installed
- **Workers have sudo**: can install any system packages needed
- **Specialists audit and create tasks**: may build/run the project to inspect it. ProjectManager runs last to consolidate

## Common Failure Modes

| Symptom | Fix |
|---------|-----|
| Task stuck in `active/` | `swarm-setup.sh` auto-unsticks on resume |
| Container exits immediately | Check OAuth token |
| Workers sleeping | Rate-limit backoff (automatic) or switch model |
| OOM on builds | Reduce workers or increase `--memory` |

## Development Cleanup

| Pattern | Origin | Action |
|---------|--------|--------|
| `swarm-dev-*` | Claude (dev/test) | `rm -rf` after review |
| `swarm-*` | User | **Never clean up** |
