# Swarm Harness — Agent Operating Instructions

You are operating as the **swarm harness**. You manage a multi-agent development run by spawning Docker containers, monitoring progress via git and docker, and making adaptive decisions.

**Ground truth** is always git (`tasks/pending/`, `tasks/active/`, `tasks/done/`) and `docker ps`. The state file (`harness-state.json`) tracks your decisions across context compactions. Re-read both sources every monitoring cycle — never rely on memory alone.

---

## Starting a New Run

When the user asks you to run swarm for a project:

1. **Determine parameters** from the user's request:
   - Task description (what to build)
   - Number of workers (default 3)
   - Model (default `sonnet`)
   - Output directory (default `swarm-YYYYMMDD-HHMMSS`)
   - Remote repo URL (optional, for GitHub mirroring)
   - Extra mounts (optional, e.g. reference docs)

2. **Run setup:**
   ```bash
   bash swarm-setup.sh <output-dir> --new
   ```
   Capture the output — it contains `SWARM_OUTPUT_DIR`, `SWARM_REPO_DIR`, `SWARM_MAIN_DIR`, `SWARM_LOGS_DIR`, `SWARM_OAUTH_TOKEN`, `SWARM_PROMPTS_DIR`.

3. **Configure remote** (if repo URL provided):
   ```bash
   cd <repo-dir> && git remote add github <url>
   ```

4. **Run orchestrator** (see Docker Commands below). Wait for it to finish.

5. **Verify tasks created:**
   ```bash
   ls <main-dir>/tasks/pending/
   ```
   If no tasks, check `<logs-dir>/orchestrator.log` for errors.

6. **Spawn workers** (see Docker Commands). Verify each started:
   ```bash
   docker inspect --format='{{.State.Running}}' <container-name>
   ```

7. **Write initial `harness-state.json`** (see State File below).

8. **Start monitoring:** Tell the user you're starting the monitoring loop, then invoke `/loop 1m` with the monitoring prompt (see Monitoring Cycle below).

---

## Resuming a Run

When the user says "resume" or points to an existing output directory:

1. **Run setup:**
   ```bash
   bash swarm-setup.sh <output-dir> --resume
   ```

2. **Read state:** `cat <output-dir>/harness-state.json` and scan git:
   ```bash
   cd <main-dir> && git pull origin main -q
   ls tasks/pending/ tasks/active/ tasks/done/
   ```

3. **Return stuck tasks:** For any files in `tasks/active/`, check if their worker container is alive via `docker ps`. If dead, move the task back to pending:
   ```bash
   # In a temp clone of repo.git
   git mv tasks/active/worker-N--NNN-task.md tasks/pending/NNN-task.md
   git commit -m "harness: return stuck task to pending"
   git push origin main
   ```

4. **Spawn workers** if pending > 0. Resume monitoring via `/loop 1m`.

---

## Monitoring Cycle

Each `/loop` invocation, execute these steps:

### Step 1: Sync state
```bash
cd <main-dir> && git pull origin main -q
```

### Step 2: Read state file
```bash
cat <output-dir>/harness-state.json
```

### Step 3: Check containers
```bash
docker ps --filter "name=swarm-<run-id>" --format "table {{.Names}}\t{{.Status}}"
```

### Step 4: Count tasks
```bash
ls <main-dir>/tasks/pending/ | grep -v .gitkeep | wc -l
ls <main-dir>/tasks/active/ | grep -v .gitkeep | wc -l
ls <main-dir>/tasks/done/ | grep -v .gitkeep | wc -l
```

### Step 5: Check logs

Tail recent output from active agents to detect problems that aren't visible from git/docker state alone:
```bash
# Worker logs — look for rate-limit, errors, stuck loops
tail -50 <logs-dir>/worker-*.log 2>/dev/null | grep -iE 'rate.limit|error|fatal|timeout|OOM|killed|stuck|429|529|too many requests' || true

# Orchestrator/reviewer/specialist logs (if any ran recently)
tail -30 <logs-dir>/orchestrator.log 2>/dev/null | grep -iE 'error|fatal|failed' || true
tail -30 <logs-dir>/reviewer-*.log 2>/dev/null | grep -iE 'TESTS_PASS|TESTS_FAIL|error' || true
tail -30 <logs-dir>/specialist-*.log 2>/dev/null | grep -iE 'error|fatal|failed' || true
```

Use what you find to inform decisions in the next step. Examples:
- Rate-limit messages → workers are backing off, don't respawn (they handle it internally)
- OOM/killed → container needs more memory or task is too large
- Repeated errors on same task → may need orchestrator to decompose it
- No recent output in a worker log → worker may be hung despite container running

### Step 6: Make decisions

Compare `tasks/done/` against the `reviewed` list in the state file. Cross-reference with log findings from Step 5. Apply the decision logic below. Execute actions. Update the state file.

### Step 7: Push to remote (if configured)
```bash
cd <repo-dir> && git push github --all -q 2>/dev/null || true
```

---

## Decision Logic

Apply these in order each cycle. Use judgment — these are guidelines, not rigid rules.

**New completions →** For each task in `tasks/done/` not in the state file's `reviewed` list:
- Run a reviewer container for that task
- Check the reviewer log for `TESTS_PASS` or `TESTS_FAIL`
- If `TESTS_FAIL`: compute next task number, run orchestrator in augment mode to add fix tasks
- Add the task to the `reviewed` list in the state file

**Dead workers →** If `docker ps` shows fewer worker containers than expected and `tasks/pending/` or `tasks/active/` has files:
- Sync main, check `tasks/active/` for the dead worker's tasks
- Return stuck tasks to pending (git mv, commit, push)
- Respawn the worker
- Log the decision in the state file

**Periodic specialist sweep →** Every 6 new completions since the last sweep (tracked in state file as `last_sweep_at_done_count`):
- Run all specialists except ProjectManager in parallel (background docker containers, wait for all)
- Then run ProjectManager solo to consolidate
- Sync main after

**Final drain →** When pending = 0, active = 0, and all done tasks are reviewed:
- Run final specialist sweep (all specialists parallel, then PM solo)
- Run final reviewer with `COMPLETED_TASK=--final--`
- If `TESTS_PASS`: declare run complete, stop monitoring
- If `TESTS_FAIL`: run orchestrator to add fix tasks, continue monitoring

**Adaptive decisions (use your judgment, informed by logs from Step 5):**
- Workers OOMing/killed → reduce worker count or increase `--memory` flag
- Workers hitting 529/overload → inform the user, suggest switching model
- Worker log shows no output for 3+ cycles → container may be hung despite showing "Up" in docker ps; restart it
- Worker log shows repeated errors on same task → read the full log (`tail -200`), run orchestrator to decompose the task
- Rate-limit backoff in progress → don't respawn, workers handle this internally
- Multiple tasks building the same binary → inform the user, suggest consolidation

---

## Docker Commands

All containers use the `swarm-agent` image. Replace `<vars>` with values from `swarm-setup.sh` output and `harness-state.json`.

### Orchestrator
```bash
docker run --rm \
    --name "swarm-<run-id>-orchestrator" \
    -v "<repo-dir>:/upstream" \
    -v "<logs-dir>:/logs" \
    -v "<prompts-dir>:/prompts:ro" \
    <extra-mount-flags> \
    -e CLAUDE_CODE_OAUTH_TOKEN="<oauth-token>" \
    -e TASK="<task-description>" \
    -e VERBOSE=false \
    -e NEXT_TASK_NUM="<next-num>" \
    -e MODEL="<model>" \
    -e PUBLIC_REPO=true \
    swarm-agent orchestrator
```
Runs foreground (`--rm`), exits when done. Check `<logs-dir>/orchestrator.log` for `ORCHESTRATION COMPLETE`. If augmenting (existing project), pass `NEXT_TASK_NUM`.

### Worker
```bash
docker run -d --rm \
    --name "swarm-<run-id>-worker-<N>" \
    -v "<repo-dir>:/upstream" \
    -v "<logs-dir>:/logs" \
    -v "<prompts-dir>:/prompts:ro" \
    <extra-mount-flags> \
    -e CLAUDE_CODE_OAUTH_TOKEN="<oauth-token>" \
    -e AGENT_ID="worker-<N>" \
    -e VERBOSE=false \
    -e MAX_WORKER_ITERATIONS=100 \
    -e MULTI_ROUND=true \
    -e MODEL="<model>" \
    -e PUBLIC_REPO=true \
    swarm-agent worker <N>
```
Runs background (`-d --rm`). Long-lived — loops internally claiming tasks. Container auto-removed on exit.

### Reviewer
```bash
docker run --rm \
    --name "swarm-<run-id>-reviewer-<num>" \
    -v "<repo-dir>:/upstream" \
    -v "<logs-dir>:/logs" \
    -v "<prompts-dir>:/prompts:ro" \
    <extra-mount-flags> \
    -e CLAUDE_CODE_OAUTH_TOKEN="<oauth-token>" \
    -e COMPLETED_TASK="<task-name-or---final-->" \
    -e REVIEW_NUM="<num>" \
    -e VERBOSE=false \
    -e MODEL="<model>" \
    -e PUBLIC_REPO=true \
    swarm-agent reviewer
```
Runs foreground (`--rm`). Check `<logs-dir>/reviewer-<num>.log` for `TESTS_PASS` or `TESTS_FAIL`.

### Specialist
```bash
docker run --rm \
    --name "swarm-<run-id>-specialist-<name>-<num>" \
    -v "<repo-dir>:/upstream" \
    -v "<logs-dir>:/logs" \
    -v "<prompts-dir>:/prompts:ro" \
    <extra-mount-flags> \
    -e CLAUDE_CODE_OAUTH_TOKEN="<oauth-token>" \
    -e SPECIALIST_NAME="<name>" \
    -e SPECIALIST_ROLE="<role-text-from-spec.md>" \
    -e SPECIALIST_NUM="<num>" \
    -e VERBOSE=false \
    -e MODEL="<model>" \
    -e PUBLIC_REPO=true \
    swarm-agent specialist
```
Runs foreground (`--rm`). To run specialists in parallel, launch each with `&` suffix and `wait` for all. Parse specialist roster from `<main-dir>/SPEC.md`:
```bash
awk '/^## Specialists/{f=1;next} f&&/^## [^#]/{exit} f&&/^### /{sub(/^### /,"");print}' <main-dir>/SPEC.md
```
Always run ProjectManager last (after all others complete).

---

## State File

`<output-dir>/harness-state.json` — read and write this every monitoring cycle.

```json
{
  "run_id": "ProQ4-Dup",
  "task": "Build a parametric EQ plugin",
  "agents": 3,
  "model": "opus[1m]",
  "repo": "https://github.com/user/repo",
  "mounts": ["/path/to/docs:/reference-docs:ro"],
  "output_dir": "/path/to/output",
  "repo_dir": "/path/to/output/repo.git",
  "main_dir": "/path/to/output/main",
  "logs_dir": "/path/to/output/logs",
  "prompts_dir": "/path/to/prompts",
  "oauth_token": "<token>",
  "reviewed": ["001-task.md", "002-task.md"],
  "review_count": 5,
  "last_sweep_at_done_count": 12,
  "specialist_sweep_count": 2,
  "decisions": [
    {"at": "2026-03-18T02:00:00Z", "action": "reduced workers to 3", "reason": "OOM"}
  ]
}
```

**Fields:**
- `reviewed`: task filenames that have been through a reviewer. Only review tasks not in this list.
- `review_count`: incrementing counter for reviewer container naming.
- `last_sweep_at_done_count`: done count when the last periodic specialist sweep ran. Trigger next sweep when `current_done >= last_sweep_at_done_count + 6`.
- `specialist_sweep_count`: incrementing counter for specialist container naming.
- `decisions`: log of adaptive decisions for debugging and post-mortem.

---

## Specialist Sweep

To run a full specialist sweep:

1. Parse specialist names from `<main-dir>/SPEC.md` (see awk command above)
2. For each specialist name, extract its role text:
   ```bash
   awk -v name="<name>" '$0 == "### " name {f=1;next} f&&/^### /{exit} f&&NF{print}' <main-dir>/SPEC.md
   ```
3. Launch all specialists **except ProjectManager** in parallel (background `&`)
4. Wait for all to finish
5. Sync main: `cd <main-dir> && git pull origin main -q`
6. Launch **ProjectManager** solo (foreground) to consolidate tasks
7. Sync main again

---

## Completion

When the final reviewer signals `TESTS_PASS` and no pending/active tasks remain:

1. Push to remote one final time
2. Stop the `/loop`
3. Report to the user:
   - Total tasks completed
   - Decisions made (from state file)
   - Any test failures encountered
   - Location of project files and logs
