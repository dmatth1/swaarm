# Multi-Round Orchestration — Design Spec
*2026-03-14*

## Goal

Add a reviewer agent that runs after each task completion, in parallel with workers, to catch integration gaps and interface deviations as work lands — not just at the end.

## Problem Statement

The current system runs one orchestration pass upfront, then workers execute until the queue is empty. Any planning mistakes, interface mismatches, or integration gaps are only caught by the final verification task — a single worker trying to fix everything at once. For large projects, this is too late.

## Design

### Overview

A new **reviewer** role runs alongside workers. Each time a task moves to `tasks/done/`, the bash harness triggers a serialized reviewer container. The reviewer reads what was actually built, compares it to SPEC.md, and can:
- Add new tasks to `tasks/pending/`
- Update `## Interfaces` in SPEC.md to reflect actual implementations
- Signal `ALL_COMPLETE` when all work is done and verified

Workers run continuously. They do not exit when the queue empties — they sleep and wait for new tasks the reviewer might add. The harness kills all workers when it receives `ALL_COMPLETE` from the reviewer.

### Multi-Round is Always On (Docker Mode)

Multi-round review is not opt-in — it is the default behavior for all Docker-mode runs. No new flag is added. `swarm.state` writes `SWARM_MULTI_ROUND=true` for Docker runs and `SWARM_MULTI_ROUND=false` for `--no-docker` runs. The `--no-docker` path is unchanged.

### New File: `prompts/reviewer.md`

The reviewer prompt receives `COMPLETED_TASK` (the bare filename, e.g. `003-routes.md`, or the sentinel value `--final--` for the drain-check pass) and `REVIEW_NUM` (sequence number for logging).

Reviewer protocol:
1. `git pull origin main`
2. Read SPEC.md architecture: `awk '/^## Interfaces/{exit} {print}' SPEC.md`
3. If `COMPLETED_TASK` is not `--final--`: read `cat tasks/done/{{COMPLETED_TASK}}` and review what was built (`git log --oneline -5`, read files in `## Produces`)
4. If `COMPLETED_TASK` is `--final--`: review overall project state — scan all done tasks, check success criteria
5. Scan `tasks/pending/` and `tasks/done/` for current state
6. Optionally: add task files to `tasks/pending/`, update `SPEC.md ## Interfaces`
7. Commit and push any changes (via Claude's tool use — no shell-level commit needed after the Claude call)
8. Signal:
   - `<promise>ALL_COMPLETE</promise>` — when `tasks/pending/` is empty, `tasks/active/` is empty, and all SPEC.md success criteria are met
   - `<promise>REVIEW_DONE</promise>` — otherwise (work continues)

The reviewer **never** removes or modifies existing tasks. It only adds.

The harness detects signals with `grep -q "ALL_COMPLETE"` (substring match) on the log file — the XML tag `<promise>ALL_COMPLETE</promise>` matches this pattern.

### Changes to `docker/entrypoint.sh`

**New reviewer mode** (`entrypoint.sh reviewer <task_name> <review_num>`):
- Clone `/upstream` → `/workspace`
- Substitute `{{COMPLETED_TASK}}` and `{{REVIEW_NUM}}` into the reviewer prompt
- Run Claude **once** (not in a loop), piping stdout to `/logs/reviewer-N.log`:
  ```bash
  echo "$prompt" | claude --dangerously-skip-permissions -p >> "$log_file" 2>&1
  ```

**Worker mode change** — add `MULTI_ROUND` env var support. The `run_worker` function reads `agent_id` from positional arg `$2` (not `$1` — `$1` is the role). The `MULTI_ROUND` env var is read directly from the environment.

Two exit paths must both be suppressed when `MULTI_ROUND=true`:

1. **Bash-level early exit** (lines 97–107): when `pending=0 AND own_active=0 AND all_active=0`, currently calls `exit 0`. Change to: if `MULTI_ROUND=true`, sleep 15 and continue; otherwise exit as today.

2. **Signal-based exit** (lines 122–126): currently `grep -q "ALL_DONE\|NO_TASKS\|WORKER.*DONE"` exits on all three patterns. When `MULTI_ROUND=true`, suppress **all three** — do not exit on any signal, loop again. The harness kills workers explicitly via `cleanup_docker`.

### Changes to `swarm` bash script

**New function: `docker_run_reviewer(task_name, review_num)`**

- Container name: `swarm-${RUN_ID}-reviewer-${review_num}`
- `task_name` is the bare filename or `--final--` — passed as `COMPLETED_TASK=$task_name`
- Passes `REVIEW_NUM=$review_num`
- Logs to `$LOGS_DIR/reviewer-${review_num}.log`
- Runs `--rm` (synchronous/blocking, same pattern as `docker_run_orchestrator`)

**Modified `docker_run_worker()`**: passes `-e MULTI_ROUND=true`.

**New function: `run_with_review(agents)`** — replaces the inline worker-spawn-and-wait block in `main()`:

```
run_with_review(agents):
  # Spawn workers (MULTI_ROUND=true, run in background)
  for i in 1..agents: docker_run_worker(i)

  monitor_progress &
  monitor_pid=$!

  reviewed=[]
  review_count=0
  max_reviews = MAX_WORKER_ITERATIONS * agents   # safety valve
  all_complete=false

  while not all_complete:
    sleep 5
    sync_main

    new_reviews_this_cycle=0
    for task_file in $MAIN_DIR/tasks/done/*.md:
      task_name = basename(task_file)
      if task_name == ".gitkeep": skip
      if task_name in reviewed: skip

      review_count++
      new_reviews_this_cycle++
      if review_count > max_reviews:
        warn "Max reviews reached — forcing stop"
        all_complete=true; break

      docker_run_reviewer(task_name, review_count)   # blocking
      reviewed.append(task_name)
      if grep -q "ALL_COMPLETE" $LOGS_DIR/reviewer-${review_count}.log:
        all_complete=true; break

    # Final-drain check: no new tasks this cycle AND queue is fully idle →
    # run one final pass with sentinel "--final--" to confirm completion.
    # Uses "--final--" (not a task filename) so the reviewer does a full
    # project-state review rather than looking for a specific done task.
    if not all_complete and new_reviews_this_cycle == 0:
      if pending_count == 0 and active_count == 0:
        review_count++
        if review_count > max_reviews:
          warn "Max reviews reached — forcing stop"
          all_complete=true
        else:
          docker_run_reviewer("--final--", review_count)
          if grep -q "ALL_COMPLETE" $LOGS_DIR/reviewer-${review_count}.log:
            all_complete=true

    if not all_complete: log progress

  kill monitor_pid
  cleanup_docker   # kills all worker containers
```

**`swarm.state` update**: write `SWARM_MULTI_ROUND=true` for Docker runs, `SWARM_MULTI_ROUND=false` for `--no-docker` runs.

**`cmd_resume` update**: sources `SWARM_MULTI_ROUND` from `swarm.state` (use `"${SWARM_MULTI_ROUND:-false}"` to handle missing values safely). When `true`:
1. **Skip the early-exit check** (`if [[ "$pending" -eq 0 ]]; then exit 0` at lines 336–340) — pending=0 is a normal transient state in multi-round
2. Call `run_with_review(agents)` instead of the single-round `docker_run_worker` + `docker_wait_workers` path

**`main()` update**: call `run_with_review(NUM_AGENTS)` when `USE_DOCKER=true`. Do not call `docker_wait_workers` in this path.

## Files to Change

- `prompts/reviewer.md` — new file
- `docker/entrypoint.sh`:
  - New `reviewer` mode with single Claude run, stdout piped to log
  - Worker mode: suppress both exit paths when `MULTI_ROUND=true`; note `agent_id` is arg `$2`
- `swarm`:
  - New `docker_run_reviewer(task_name, review_num)`
  - `docker_run_worker()` passes `-e MULTI_ROUND=true`
  - New `run_with_review(agents)` with final-drain sentinel and max-review safety valve
  - `main()` calls `run_with_review()` instead of inline worker spawn + wait (Docker path)
  - `cmd_resume()`: skip pending=0 early exit when `${SWARM_MULTI_ROUND:-false}==true`; call `run_with_review()`
  - `swarm.state` writes `SWARM_MULTI_ROUND=true/false`

## Success Criteria

- [ ] Reviewer runs after each task completion while other workers are still active
- [ ] Reviewer can add tasks that workers pick up without restart
- [ ] Reviewer can update SPEC.md `## Interfaces` to fix interface deviations
- [ ] Workers sleep (don't exit) when queue is empty — harness kills them on `ALL_COMPLETE`
- [ ] `ALL_COMPLETE` in reviewer log terminates the run and kills workers
- [ ] Final-drain pass with `--final--` correctly identifies completion when queue drains to zero
- [ ] Max-review safety valve prevents infinite loops
- [ ] `swarm resume` on a multi-round run calls `run_with_review()` and skips pending=0 early exit
- [ ] `--no-docker` mode is unaffected
- [ ] Reviewer logs appear at `logs/reviewer-N.log` for each task reviewed
