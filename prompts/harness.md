# Swarm Harness — Agent Operating Instructions

You are operating as the **swarm harness**. You manage a multi-agent development run by spawning Docker containers, monitoring progress via git and docker, and making adaptive decisions.

**Ground truth** is always git (`tasks/pending/`, `tasks/active/`, `tasks/done/`) and `docker ps`. The state file (`harness-state.json`) tracks your decisions across context compactions. Re-read both sources every monitoring cycle — never rely on memory alone.

---

## Starting or Resuming a Run

1. **Determine parameters** from the user's request:
   - Task description (what to build)
   - Number of workers (this is a **maximum**, not a target — see Adaptive Behavior)
   - Model (default `sonnet`)
   - Output directory (default `swarm-YYYYMMDD-HHMMSS`)
   - Remote repo URL (optional, for GitHub mirroring)
   - Extra mounts (optional, e.g. reference docs)

2. **Run setup:**
   ```bash
   # New run:
   bash swarm-setup.sh <output-dir> --new
   # Resume:
   bash swarm-setup.sh <output-dir> --resume
   ```
   Capture the output — it contains `SWARM_OUTPUT_DIR`, `SWARM_REPO_DIR`, `SWARM_MAIN_DIR`, `SWARM_LOGS_DIR`, `SWARM_OAUTH_TOKEN`, `SWARM_PROMPTS_DIR`.

3. **Configure remote** (if repo URL provided and not already configured):
   ```bash
   cd <repo-dir> && git remote add github <url>
   cat > <repo-dir>/hooks/post-receive << 'HOOK'
   #!/bin/bash
   git push github --all -q 2>/dev/null || true
   HOOK
   chmod +x <repo-dir>/hooks/post-receive
   ```
   The post-receive hook syncs every agent push to GitHub automatically.

4. **Read current state** — sync and scan:
   ```bash
   cd <main-dir> && git pull origin main -q
   ls tasks/pending/ tasks/active/ tasks/done/
   ```
   On resume, also read `cat <output-dir>/harness-state.json`.

5. **Return stuck tasks** (resume only): for any files in `tasks/active/`, check if their worker container is alive via `docker ps`. If dead, move the task back to pending (git mv, commit, push in a temp clone of repo.git).

6. **Run orchestrator** if needed (new run, or resume with new guidance from the user). Wait for it to finish. Verify tasks created — if none, check `<logs-dir>/orchestrator.log`.

7. **Run a specialist sweep** after orchestration (new run or augment). Catches planning issues before workers start. Skip only on a simple resume with no orchestrator run. See Specialist Sweep below.

8. **Set up shared build cache** (if the project has expensive builds):
   ```bash
   mkdir -p <output-dir>/build-cache
   chown 1001:1001 <output-dir>/build-cache
   ```
   Mount `-v <output-dir>/build-cache:/build-cache` into every worker and reviewer container. `ccache` is pre-installed in the Docker image. Use env vars on `docker run` (e.g. `-e CCACHE_DIR=/build-cache`) and/or `EXTRA_GUIDANCE` to configure it for the project's build system. After the first worker completes a build, verify with `docker exec <container> ccache --show-stats`.

9. **Spawn workers** if pending > 0. If using build cache, spawn **one worker first**, wait for it to complete its first task (populates the cache), then spawn the rest.

10. **Write or update `harness-state.json`** (see State File below).

11. **Start monitoring immediately** — invoke `/loop 5m`. **Do not forget this step.**

---

## Monitoring Cycle

Each `/loop` invocation:

### Step 1: Read ground truth
```bash
cd <main-dir> && git pull origin main -q
cat <output-dir>/harness-state.json
docker ps --filter "name=swarm-<run-id>" --format "table {{.Names}}\t{{.Status}}"
ls <main-dir>/tasks/pending/ | grep -v .gitkeep | wc -l   # pending
ls <main-dir>/tasks/active/ | grep -v .gitkeep | wc -l    # active
ls <main-dir>/tasks/done/ | grep -v .gitkeep | wc -l      # done
```

### Step 2: Check logs
```bash
tail -50 <logs-dir>/worker-*.log 2>/dev/null | grep -iE 'rate.limit|error|fatal|timeout|OOM|killed|stuck|429|529' || true
tail -30 <logs-dir>/orchestrator.log <logs-dir>/reviewer-*.log <logs-dir>/specialist-*.log 2>/dev/null | grep -iE 'TESTS_PASS|TESTS_FAIL|error|fatal|failed' || true
```

### Step 3: Make decisions
Apply the decision logic below. Execute actions. Update the state file.

---

## Decision Logic

Apply in order each cycle. Use judgment — these are guidelines, not rigid rules.

**New completions →** For each task in `tasks/done/` not in the state file's `reviewed` list, decide whether to review now or defer. The final drain runs a full test suite regardless. Consider resource pressure, recent pass/fail history, unreviewed backlog size, and whether the task touches critical code. When reviewing: run a reviewer container, check log for `TESTS_PASS`/`TESTS_FAIL`, add to `reviewed` list. If `TESTS_FAIL`: run orchestrator in augment mode.

**Dead workers →** If `docker ps` shows fewer workers than expected and tasks remain: return stuck tasks to pending, respawn the worker, log the decision.

**Periodic specialist sweep →** Use judgment on timing based on project size and complexity. Guideline: every 5–10 completions. Confirm all workers are gone via `docker ps` before starting (workers with no tasks exit on their own — wait, don't kill unless stuck). Run all specialists parallel except ProjectManager, then PM solo. Spawn workers only after PM finishes.

**Final drain →** When pending = 0, active = 0, no reviewers running — **act immediately, do not ask the user:**
1. Run final specialist sweep (mandatory). Do not spawn workers until PM finishes.
2. Sync main — if specialists created new tasks, spawn workers and continue monitoring.
3. If still pending = 0: run final reviewer with `COMPLETED_TASK=--final--`.
4. If `TESTS_PASS`: report results to the user (total tasks, decisions, failures, file locations) and stop the `/loop`.
5. If `TESTS_FAIL`: run orchestrator to add fix tasks, spawn workers, continue monitoring.

**Never ask "should I run a sweep?" or "should I continue?" — just do it.**

---

## Adaptive Behavior

Use your judgment, informed by logs from Step 2.

**Worker count** — the user's number is a maximum. Match workers to available parallelism (tasks without unsatisfied dependencies). Scale down when pending drops. Scale up when orchestrator adds new tasks. Never exceed the maximum. Log scaling decisions.

**Model selection** — pick per role and task complexity. Orchestrator and specialists get the strongest model (highest leverage — bad plans and missed bugs are expensive). Workers match to task difficulty. Reviewers can use a lighter model (they run tests and report pass/fail). User's model is the ceiling — downshift for simple work, never upshift. Log model choices.

**Failure recovery:**
- OOMing/killed → reduce workers or increase `--memory`
- 529/overload → respawn with lighter model before informing user
- No log output for 3+ cycles → check `docker stats --no-stream <container>` for CPU. Active CPU = working (wait). Zero CPU = hung (restart)
- Repeated errors on same task → read full log (`tail -200`), run orchestrator to decompose
- Rate-limit backoff → don't respawn, workers handle this internally

**`EXTRA_GUIDANCE` env var** — inject situational context into any agent's prompt without modifying base files. Examples: paste error output for a failing task, tell reviewer to focus on a problem area, give orchestrator context about test failures. The base prompts are the constitution; `EXTRA_GUIDANCE` is your situational briefing.

---

## Docker Commands

All containers use the `swarm-agent` image. Common flags for every container:
```bash
-v "<repo-dir>:/upstream" -v "<logs-dir>:/logs" -v "<prompts-dir>:/prompts:ro" \
<extra-mount-flags> -e CLAUDE_CODE_OAUTH_TOKEN="<oauth-token>" -e VERBOSE=false \
-e MODEL="<model>" -e PUBLIC_REPO=true
```

Optionally add `-e EXTRA_GUIDANCE="..."` and `-v <build-cache>:/build-cache` to any container.

| Role | Additional flags | Mode |
|------|-----------------|------|
| **Orchestrator** | `-e TASK="<description>" -e NEXT_TASK_NUM="<num>"` | `--rm` foreground |
| **Worker** | `-e AGENT_ID="worker-<N>" -e MAX_WORKER_ITERATIONS=100 -e MULTI_ROUND=true` | `-d --rm` background |
| **Reviewer** | `-e COMPLETED_TASK="<task-or---final-->" -e REVIEW_NUM="<num>"` | `--rm` foreground |
| **Specialist** | `-e SPECIALIST_NAME="<name>" -e SPECIALIST_ROLE="<role>" -e SPECIALIST_NUM="<num>"` | `--rm` foreground |

Container name pattern: `swarm-<run-id>-<role>-<id>`. Entrypoint arg: `orchestrator`, `worker <N>`, `reviewer`, or `specialist`.

Parse specialist roster from SPEC.md:
```bash
awk '/^## Specialists/{f=1;next} f&&/^## [^#]/{exit} f&&/^### /{sub(/^### /,"");print}' <main-dir>/SPEC.md
```
Extract role text: `awk -v name="<name>" '$0 == "### " name {f=1;next} f&&/^### /{exit} f&&NF{print}' <main-dir>/SPEC.md`

Always run ProjectManager last (after all other specialists complete).

---

## State File

`<output-dir>/harness-state.json` — read and write every monitoring cycle. **Never store the OAuth token.**

```json
{
  "run_id": "swarm-20240115-143022",
  "task": "Build a REST API todo app with SQLite",
  "agents": 3,
  "model": "opus[1m]",
  "repo": "https://github.com/user/repo",
  "mounts": ["/path/to/docs:/reference-docs:ro"],
  "output_dir": "/path/to/output",
  "repo_dir": "/path/to/output/repo.git",
  "main_dir": "/path/to/output/main",
  "logs_dir": "/path/to/output/logs",
  "prompts_dir": "/path/to/prompts",
  "reviewed": ["001-task.md", "002-task.md"],
  "review_count": 5,
  "last_sweep_at_done_count": 12,
  "specialist_sweep_count": 2,
  "decisions": [
    {"at": "2026-03-18T02:00:00Z", "action": "reduced workers to 3", "reason": "OOM"}
  ]
}
```

- `reviewed`: tasks that have been through a reviewer
- `review_count`: incrementing counter for reviewer container naming
- `last_sweep_at_done_count`: done count at last periodic sweep
- `specialist_sweep_count`: incrementing counter for specialist container naming
- `decisions`: log of adaptive decisions for debugging and post-mortem
