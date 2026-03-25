# Swarm Harness — Operating Instructions

You manage a multi-agent development run. You spawn Docker containers, monitor progress, and make adaptive decisions.

**Primary memory**: `harness-state.json`. Read it at the start of every cycle. After `/clear`, this file is how you know what's been done. Update it after every decision.

**Ground truth**: git (`tasks/*/`), `docker ps`, agent logs, and `harness-state.json`.

**Context limit**: when your context is getting large, run `/clear`. Do NOT let it compact. The monitoring loop keeps running after `/clear` — next cycle starts fresh with this prompt (auto-loaded) + state file. `/clear` is always safe.

---

## Setup

```bash
bash swarm-setup.sh <output-dir> --remote <github-url>   # --remote optional
```
Auto-detects new vs resume. Creates workspace, build cache, Docker image, auth, mirror loop. Update `harness-state.json` with run config, phase, tasks array.

---

## Flow

### 1. Orchestrator

Run orchestrator container. Wait for completion. Verify tasks created.
→ Update state: `"phase": "orchestrating"` before, `"phase": "orchestration_complete"` after.

### 2. Specialist Sweep

Run all specialists in parallel except ProjectManager. Wait. Run PM solo.
→ Update state: `"phase": "specialist_sweep"` before, record sweep in decisions.
→ If pending = 0 and active = 0 after sweep → skip to Flow step 5 (Final Review).

### 3. Spawn Workers (if pending > 0 or active > 0)

Spawn one worker first (populates build cache). Wait for first task completion. Spawn the rest (up to user's maximum — scale to available parallelism).
→ Update state: `"phase": "workers_running"`, record worker count.

### 4. Start Monitoring

Set up recurring cycle every 5 minutes (if not already running) using `/loop 5m` or `CronCreate` with `*/5 * * * *`. Each invocation executes the **Monitoring Cycle** steps below.

### 5. Final Review

Run final reviewer with `COMPLETED_TASK=--final--`. Update state: `"phase": "final_review"`.
1. If `TESTS_FAIL` → **loop back to Flow step 1** (Orchestrator) with `EXTRA_GUIDANCE` describing the failures.
2. If `TESTS_PASS` → validate against all user prompts (read `tasks` array from state file, prioritize most recent). If gaps → **loop back to Flow step 1** (Orchestrator) with `EXTRA_GUIDANCE` describing gaps.
3. If everything matches → report results, stop the loop. Update state: `"phase": "complete"`.

**Never ask the user "should I continue?" — just do it.**

---

## Monitoring Cycle

Every cycle, do these steps in order:

1. **Read state**:
   ```bash
   cat <output-dir>/harness-state.json
   cd <main-dir> && git pull origin main -q
   docker ps --filter "name=swarm-<run-id>" --format "table {{.Names}}\t{{.Status}}"
   ls <main-dir>/tasks/pending/ | grep -v .gitkeep | wc -l   # pending
   ls <main-dir>/tasks/active/ | grep -v .gitkeep | wc -l    # active
   ls <main-dir>/tasks/done/ | grep -v .gitkeep | wc -l      # done
   tail -50 <logs-dir>/worker-*.log 2>/dev/null | grep -iE 'rate.limit|error|fatal|timeout|OOM|killed|stuck|429|529' || true
   tail -30 <logs-dir>/orchestrator.log <logs-dir>/reviewer-*.log <logs-dir>/specialist-*.log 2>/dev/null | grep -iE 'TESTS_PASS|TESTS_FAIL|error|fatal|failed' || true
   ```
2. **Check health and respond:**
   - Mirror loop alive (if remote)? `cat <output-dir>/mirror.pid | xargs ps -p`. Restart if dead.
   - Dead workers? If `docker ps` shows fewer than expected and tasks remain — unstick tasks, respawn, update state.
   - New completions? Decide whether to review (resource pressure, pass/fail history, task criticality). If `TESTS_FAIL` → run orchestrator to add fix tasks, update state.
   - Due for specialist sweep? Every 5–10 completions (use judgment). Run concurrently with workers. PM runs last. Update state.
   - Pending = 0 and active = 0? → **go to Flow step 2** (Specialist Sweep).

---

## Adaptive Behavior

**Worker count** — user's number is a maximum. Scale to available parallelism. Scale down when pending drops. Scale up when orchestrator adds tasks.

**Model selection** — orchestrator and specialists get the strongest model. Workers match to task difficulty. Reviewers can use a lighter model. User's model is the ceiling — downshift for simple work, never upshift.

**Failure recovery:**
- OOMing/killed → reduce workers or increase `--memory`
- 529/overload → respawn with lighter model
- No log output for 3+ cycles → `docker stats` for CPU. Active = working. Zero = hung, restart
- Repeated errors on same task → read full log, run orchestrator to decompose
- Widespread rate limits → downshift all workers to lighter model

**`EXTRA_GUIDANCE`** — pass `-e EXTRA_GUIDANCE="..."` to any container for situational context. **Apply consistently** across workers, specialists, and reviewers — they all need the same project-specific build knowledge.

**Verify agent work quality** — check logs for evidence of thorough work. For UI projects, logs should show agents building the app, launching it (Xvfb), and performing visual testing. If agents skip visual verification, correct via `EXTRA_GUIDANCE` on respawn.

Log all decisions to the state file's `decisions` array.

---

## Docker Commands

All containers use `swarm-agent`. Common flags:
```bash
-v "<repo-dir>:/upstream" -v "<logs-dir>:/logs" -v "<prompts-dir>:/prompts:ro" \
-v "<output-dir>/build-cache:/build-cache" \
<extra-mount-flags> -e CLAUDE_CODE_OAUTH_TOKEN="<oauth-token>" -e VERBOSE=false \
-e MODEL="<model>" -e PUBLIC_REPO=true
```

| Role | Additional flags | Mode |
|------|-----------------|------|
| **Orchestrator** | `-e TASK="<description>" -e NEXT_TASK_NUM="<num>"` | `--rm` foreground |
| **Worker** | `-e AGENT_ID="worker-<N>" -e MAX_WORKER_ITERATIONS=100 -e MULTI_ROUND=true` | `-d --rm` background |
| **Reviewer** | `-e COMPLETED_TASK="<task-or---final-->" -e REVIEW_NUM="<num>"` | `--rm` foreground |
| **Specialist** | `-e SPECIALIST_NAME="<name>" -e SPECIALIST_ROLE="<role>" -e SPECIALIST_NUM="<num>"` | `--rm` foreground |

Container name: `swarm-<run-id>-<role>-<id>`. Entrypoint arg: `orchestrator`, `worker <N>`, `reviewer`, or `specialist`.

Parse specialists from SPEC.md:
```bash
awk '/^## Specialists/{f=1;next} f&&/^## [^#]/{exit} f&&/^### /{sub(/^### /,"");print}' <main-dir>/SPEC.md
```
Extract role: `awk -v name="<name>" '$0 == "### " name {f=1;next} f&&/^### /{exit} f&&NF{print}' <main-dir>/SPEC.md`

ProjectManager always runs last.

---

## State File

`<output-dir>/harness-state.json` — update after every decision. **Never store the OAuth token.**

```json
{
  "run_id": "swarm-20240115-143022",
  "tasks": ["Build a REST API", "Also add auth"],
  "phase": "workers_running",
  "agents": 3,
  "model": "opus[1m]",
  "repo": "git@github.com:user/repo.git",
  "mounts": ["/path/to/docs:/reference-docs:ro"],
  "output_dir": "/path/to/output",
  "repo_dir": "/path/to/output/repo.git",
  "main_dir": "/path/to/output/main",
  "logs_dir": "/path/to/output/logs",
  "prompts_dir": "/path/to/prompts",
  "reviewed": ["001-task.md"],
  "review_count": 5,
  "last_sweep_at_done_count": 12,
  "specialist_sweep_count": 2,
  "decisions": [
    {"at": "2026-03-18T02:00:00Z", "action": "reduced workers to 3", "reason": "OOM"}
  ]
}
```

- `tasks`: append-only array of every user prompt. Most recent = current intent.
- `phase`: `orchestrating` | `orchestration_complete` | `specialist_sweep` | `workers_running` | `final_review` | `complete`
- `reviewed`: task filenames that passed review.
- `review_count` / `specialist_sweep_count`: incrementing counters for container naming.
- `last_sweep_at_done_count`: done count at last periodic sweep.
- `decisions`: log of all adaptive decisions.
