# Multi-Round Orchestration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reviewer agent that runs after each task completion while workers are still active, capable of adding tasks, updating SPEC.md interfaces, and signaling ALL_COMPLETE to terminate the run.

**Architecture:** A new `run_with_review()` function replaces the inline worker-spawn-and-wait block in `main()`. It spawns workers with `MULTI_ROUND=true` (so they sleep instead of exiting when the queue empties), then loops scanning `tasks/done/` for unreviewed tasks and runs a blocking reviewer container for each. The reviewer can add tasks workers pick up immediately. The harness kills all workers when it receives `ALL_COMPLETE`.

**Tech Stack:** bash, Docker, Claude Code CLI (`claude --dangerously-skip-permissions -p`)

**Spec:** `docs/superpowers/specs/2026-03-14-multi-round-orchestration-design.md`

---

## Chunk 1: Reviewer Prompt and Entrypoint Changes

### Task 1: Create `prompts/reviewer.md`

**Files:**
- Create: `prompts/reviewer.md`

- [ ] **Step 1: Create the reviewer prompt file**

Write `prompts/reviewer.md` with this exact content:

```markdown
# Swarm Reviewer Agent

You are the **REVIEWER** in a multi-agent development system.

Your job: review what was just built, compare it to SPEC.md, and signal whether work is complete or whether more tasks are needed.

You receive:
- `COMPLETED_TASK`: the filename of the just-completed task (e.g. `003-routes.md`), or `--final--` for a full project review
- `REVIEW_NUM`: this review's sequence number

---

## Protocol

### Step 1: Pull Latest

```bash
git pull origin main
```

### Step 2: Read Project Context

Read architecture, stack, file layout, and success criteria — but not the `## Interfaces` section:

```bash
awk '/^## Interfaces/{exit} {print}' SPEC.md
```

### Step 3: Review What Was Built

**If `COMPLETED_TASK` is not `--final--`:**

Read the completed task file:
```bash
cat tasks/done/{{COMPLETED_TASK}}
```

Check recent commits:
```bash
git log --oneline -5
```

Read the files listed in the task's `## Produces` section to verify they were actually built correctly.

**If `COMPLETED_TASK` is `--final--`:**

Do a full project review:
- Scan all done tasks: `ls tasks/done/`
- Check each success criterion in SPEC.md
- Read key project files to verify integration works

### Step 4: Assess Current Queue State

```bash
ls tasks/pending/
ls tasks/active/
```

### Step 5: Take Corrective Action (if needed)

You may:
- **Add new task files** to `tasks/pending/` if gaps, integration failures, or missing work is found
- **Update `## Interfaces`** in SPEC.md if an implementation deviates from the contract in a way that downstream tasks should know about

You must **never** modify or remove existing task files.

If you add tasks or update SPEC.md, commit and push:
```bash
git add -A
git commit -m "reviewer-{{REVIEW_NUM}}: [description of correction]"
git push origin main
```

### Step 6: Signal

Output exactly one of these signals:

Signal `<promise>ALL_COMPLETE</promise>` when ALL of the following are true:
- `tasks/pending/` is empty (no `.md` files, only `.gitkeep` allowed)
- `tasks/active/` is empty (no `.md` files)
- All SPEC.md success criteria are met

Signal `<promise>REVIEW_DONE</promise>` otherwise (work continues).

---

## Rules

- **Never remove or modify existing tasks** — only add new ones
- **Be conservative with ALL_COMPLETE** — if uncertain, signal REVIEW_DONE
- **Check actual files** — don't assume tasks were completed correctly just because they're in `tasks/done/`
- **Interface deviations**: if a worker implemented something differently than SPEC.md specifies, update `## Interfaces` to match reality before downstream tasks consume the contract
```

- [ ] **Step 2: Verify the file exists and contains the required signals**

```bash
grep -c "ALL_COMPLETE\|REVIEW_DONE" prompts/reviewer.md
```

Expected output: `2`

- [ ] **Step 3: Commit**

```bash
git add prompts/reviewer.md
git commit -m "feat: add reviewer prompt for multi-round orchestration"
```

---

### Task 2: Add reviewer mode to `docker/entrypoint.sh`

**Files:**
- Modify: `docker/entrypoint.sh`

The entrypoint currently supports `orchestrator` and `worker` modes. We need to add `reviewer` mode and also add MULTI_ROUND support to the worker loop.

- [ ] **Step 1: Add `run_reviewer()` function after `run_orchestrator()`**

In `docker/entrypoint.sh`, after the closing `}` of `run_orchestrator()` (after line 51), add:

```bash
# ─────────────────────────────────────────────────────────────
# REVIEWER MODE
# ─────────────────────────────────────────────────────────────

run_reviewer() {
    local completed_task="${COMPLETED_TASK:-}"
    local review_num="${REVIEW_NUM:-0}"
    local log_file="/logs/reviewer-${review_num}.log"

    echo "=== Reviewer ${review_num} started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone /upstream /workspace -q 2>/dev/null
    cd /workspace
    git config user.email "reviewer@swarm"
    git config user.name "Swarm Reviewer"

    # Prepare prompt — substitute COMPLETED_TASK and REVIEW_NUM
    local prompt
    prompt=$(sed -e "s|{{COMPLETED_TASK}}|${completed_task}|g" \
                 -e "s|{{REVIEW_NUM}}|${review_num}|g" \
                 /prompts/reviewer.md)

    echo "$prompt" | claude --dangerously-skip-permissions -p >> "$log_file" 2>&1 || true

    echo "=== Reviewer ${review_num} finished $(date) ===" >> "$log_file"
}
```

- [ ] **Step 2: Add `reviewer` case to the dispatch block**

At the bottom of `docker/entrypoint.sh`, the dispatch `case` block (lines 139–150) currently has:

```bash
case "$ROLE" in
    orchestrator)
        run_orchestrator
        ;;
    worker)
        run_worker "$@"
        ;;
    *)
        echo "Unknown role: $ROLE (expected orchestrator or worker)" >&2
        exit 1
        ;;
esac
```

Replace it with:

```bash
case "$ROLE" in
    orchestrator)
        run_orchestrator
        ;;
    worker)
        run_worker "$@"
        ;;
    reviewer)
        run_reviewer
        ;;
    *)
        echo "Unknown role: $ROLE (expected orchestrator, worker, or reviewer)" >&2
        exit 1
        ;;
esac
```

- [ ] **Step 3: Verify entrypoint has both reviewer function and dispatch case**

```bash
grep -n "run_reviewer()" docker/entrypoint.sh
grep -n "reviewer)" docker/entrypoint.sh
```

Expected: one line showing `run_reviewer()` function definition, one line showing the `reviewer)` case dispatch.

- [ ] **Step 4: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: add reviewer mode to Docker entrypoint"
```

---

### Task 3: Add MULTI_ROUND support to worker loop in `docker/entrypoint.sh`

**Files:**
- Modify: `docker/entrypoint.sh`

The worker loop has two exit paths that must be suppressed when `MULTI_ROUND=true`. The current code (lines 97–107 and 122–126) must be updated.

- [ ] **Step 1: Suppress the bash-level early exit when MULTI_ROUND=true**

In `run_worker()`, the current bash-level early-exit block (lines 97–107) is:

```bash
        # If no work for this agent
        if [[ "$pending" -eq 0 && "$own_active" -eq 0 ]]; then
            if [[ "$all_active" -eq 0 ]]; then
                echo "Worker $agent_id: all tasks complete" >> "$log_file"
                echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
                exit 0
            else
                # Other workers still active, wait
                sleep 5
                continue
            fi
        fi
```

Replace it with:

```bash
        # If no work for this agent
        if [[ "$pending" -eq 0 && "$own_active" -eq 0 ]]; then
            if [[ "$all_active" -eq 0 ]]; then
                if [[ "${MULTI_ROUND:-false}" == "true" ]]; then
                    # In multi-round mode, reviewer may add tasks — sleep and wait
                    sleep 15
                    continue
                fi
                echo "Worker $agent_id: all tasks complete" >> "$log_file"
                echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
                exit 0
            else
                # Other workers still active, wait
                sleep 5
                continue
            fi
        fi
```

- [ ] **Step 2: Suppress the signal-based exit when MULTI_ROUND=true**

The current signal-check block (lines 122–126) is:

```bash
        # Check completion signals
        if echo "$output" | grep -q "ALL_DONE\|NO_TASKS\|WORKER.*DONE"; then
            echo "Worker $agent_id: signaled completion" >> "$log_file"
            echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
            exit 0
        fi
```

Replace it with:

```bash
        # Check completion signals
        if echo "$output" | grep -q "ALL_DONE\|NO_TASKS\|WORKER.*DONE"; then
            if [[ "${MULTI_ROUND:-false}" == "true" ]]; then
                # In multi-round mode, harness kills workers — never self-exit on signals
                sleep 2
                continue
            fi
            echo "Worker $agent_id: signaled completion" >> "$log_file"
            echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
            exit 0
        fi
```

- [ ] **Step 3: Verify both MULTI_ROUND checks are present**

```bash
grep -c "MULTI_ROUND" docker/entrypoint.sh
```

Expected output: `2`

- [ ] **Step 4: Verify sleep durations are correct for each MULTI_ROUND block**

```bash
grep -A5 "MULTI_ROUND.*true" docker/entrypoint.sh
```

Expected: two blocks total — the bash-level block contains `sleep 15` and `continue`; the signal-based block contains `sleep 2` and `continue`. Also verify with:

```bash
grep -c "sleep 15" docker/entrypoint.sh
grep -c "sleep 2" docker/entrypoint.sh
```

Expected: at least one line for each.

- [ ] **Step 5: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: suppress worker exits in MULTI_ROUND mode"
```

---

## Chunk 2: swarm Script Changes

### Task 4: Add `docker_run_reviewer()` to `swarm`

**Files:**
- Modify: `swarm`

- [ ] **Step 1: Add `docker_run_reviewer()` function after `docker_run_worker()`**

In `swarm`, after the closing `}` of `docker_run_worker()` (after line 546), add:

```bash
docker_run_reviewer() {
    local task_name="$1"
    local review_num="$2"
    local container_name="swarm-${RUN_ID}-reviewer-${review_num}"

    local oauth_token
    oauth_token=$(get_claude_oauth_token) || true

    docker run --rm \
        --name "$container_name" \
        -v "$REPO_DIR:/upstream" \
        -v "$LOGS_DIR:/logs" \
        -v "$PROMPTS_DIR:/prompts:ro" \
        ${oauth_token:+-e CLAUDE_CODE_OAUTH_TOKEN="$oauth_token"} \
        -e COMPLETED_TASK="$task_name" \
        -e REVIEW_NUM="$review_num" \
        -e VERBOSE="$VERBOSE" \
        "$DOCKER_IMAGE" \
        reviewer || true
}
```

- [ ] **Step 2: Verify function is present**

```bash
grep -n "docker_run_reviewer" swarm
```

Expected: definition line and later a call site.

- [ ] **Step 3: Commit**

```bash
git add swarm
git commit -m "feat: add docker_run_reviewer() function"
```

---

### Task 5: Pass `-e MULTI_ROUND=true` in `docker_run_worker()`

**Files:**
- Modify: `swarm`

- [ ] **Step 1: Add MULTI_ROUND env var to `docker_run_worker()`**

In `docker_run_worker()`, the `docker run -d` block currently ends with (lines 531–541):

```bash
    docker run -d \
        --name "$container_name" \
        -v "$REPO_DIR:/upstream" \
        -v "$LOGS_DIR:/logs" \
        -v "$PROMPTS_DIR:/prompts:ro" \
        ${oauth_token:+-e CLAUDE_CODE_OAUTH_TOKEN="$oauth_token"} \
        -e AGENT_ID="worker-$agent_id" \
        -e VERBOSE="$VERBOSE" \
        -e MAX_WORKER_ITERATIONS="$MAX_WORKER_ITERATIONS" \
        "$DOCKER_IMAGE" \
        worker "$agent_id" > /dev/null
```

Replace it with:

```bash
    docker run -d \
        --name "$container_name" \
        -v "$REPO_DIR:/upstream" \
        -v "$LOGS_DIR:/logs" \
        -v "$PROMPTS_DIR:/prompts:ro" \
        ${oauth_token:+-e CLAUDE_CODE_OAUTH_TOKEN="$oauth_token"} \
        -e AGENT_ID="worker-$agent_id" \
        -e VERBOSE="$VERBOSE" \
        -e MAX_WORKER_ITERATIONS="$MAX_WORKER_ITERATIONS" \
        -e MULTI_ROUND=true \
        "$DOCKER_IMAGE" \
        worker "$agent_id" > /dev/null
```

- [ ] **Step 2: Verify**

```bash
grep "MULTI_ROUND=true" swarm
```

Expected: one match inside `docker_run_worker`.

- [ ] **Step 3: Commit**

```bash
git add swarm
git commit -m "feat: pass MULTI_ROUND=true to worker containers"
```

---

### Task 6: Add `run_with_review()` to `swarm`

**Files:**
- Modify: `swarm`

This function replaces the inline worker-spawn-and-wait block for Docker runs. Add it after `docker_wait_workers()` (after line 568).

- [ ] **Step 1: Add `run_with_review()` function**

```bash
run_with_review() {
    local agents="$1"

    # Spawn all workers in background (MULTI_ROUND=true set in docker_run_worker)
    log "Spawning $agents worker agents..."
    for i in $(seq 1 "$agents"); do
        docker_run_worker "$i"
        sleep 1
    done
    echo

    monitor_progress &
    local monitor_pid=$!

    local reviewed=()
    local review_count=0
    local max_reviews=$(( MAX_WORKER_ITERATIONS * agents ))
    local all_complete=false

    while [[ "$all_complete" == "false" ]]; do
        sleep 5
        sync_main

        local new_reviews_this_cycle=0

        # Scan done/ for unreviewed tasks
        local task_file task_name
        for task_file in "$MAIN_DIR/tasks/done/"*.md; do
            [[ -f "$task_file" ]] || continue
            task_name=$(basename "$task_file")
            [[ "$task_name" == ".gitkeep" ]] && continue

            # Skip already-reviewed tasks
            local already_reviewed=false
            local r
            for r in "${reviewed[@]+"${reviewed[@]}"}"; do
                if [[ "$r" == "$task_name" ]]; then
                    already_reviewed=true
                    break
                fi
            done
            [[ "$already_reviewed" == "true" ]] && continue

            review_count=$((review_count + 1))
            new_reviews_this_cycle=$((new_reviews_this_cycle + 1))

            if [[ "$review_count" -gt "$max_reviews" ]]; then
                warn "Max reviews ($max_reviews) reached — forcing stop"
                all_complete=true
                break
            fi

            log "Running reviewer ${review_count} for: $task_name"
            docker_run_reviewer "$task_name" "$review_count"
            reviewed+=("$task_name")

            if grep -q "ALL_COMPLETE" "$LOGS_DIR/reviewer-${review_count}.log" 2>/dev/null; then
                log "Reviewer signaled ALL_COMPLETE"
                all_complete=true
                break
            fi
        done

        # Final-drain check: no new tasks this cycle AND queue fully idle
        if [[ "$all_complete" == "false" && "$new_reviews_this_cycle" -eq 0 ]]; then
            local p_count a_count
            p_count=$(pending_count)
            a_count=$(active_count)
            if [[ "$p_count" -eq 0 && "$a_count" -eq 0 ]]; then
                review_count=$((review_count + 1))
                if [[ "$review_count" -gt "$max_reviews" ]]; then
                    warn "Max reviews ($max_reviews) reached — forcing stop"
                    all_complete=true
                else
                    log "Running final drain reviewer (${review_count})..."
                    docker_run_reviewer "--final--" "$review_count"
                    if grep -q "ALL_COMPLETE" "$LOGS_DIR/reviewer-${review_count}.log" 2>/dev/null; then
                        log "Reviewer signaled ALL_COMPLETE"
                        all_complete=true
                    fi
                fi
            fi
        fi

        if [[ "$all_complete" == "false" ]]; then
            local p a d
            p=$(pending_count)
            a=$(active_count)
            d=$(done_count)
            log "Review loop: ${d} done | ${a} active | ${p} pending | ${#reviewed[@]} reviewed"
        fi
    done

    kill "$monitor_pid" 2>/dev/null || true
    cleanup_docker
}
```

- [ ] **Step 2: Verify function is present and has both sentinel checks**

```bash
grep -c "ALL_COMPLETE" swarm
```

Expected output: `2` (one in the per-task review, one in the final-drain check).

- [ ] **Step 3: Commit**

```bash
git add swarm
git commit -m "feat: add run_with_review() orchestration loop"
```

---

### Task 7: Update `main()` to call `run_with_review()`

**Files:**
- Modify: `swarm`

`main()` currently has an inline worker-spawn-and-wait block for Docker at lines 910–918:

```bash
    local failed=0
    if [[ "$USE_DOCKER" == "true" ]]; then
        for i in $(seq 1 "$NUM_AGENTS"); do
            docker_run_worker "$i"
            sleep 1
        done
        monitor_progress &
        local monitor_pid=$!
        failed=$(docker_wait_workers "$NUM_AGENTS")
        kill "$monitor_pid" 2>/dev/null || true
    else
```

- [ ] **Step 1: Replace the Docker worker-spawn block with `run_with_review()`**

Replace the lines above with:

```bash
    local failed=0
    if [[ "$USE_DOCKER" == "true" ]]; then
        run_with_review "$NUM_AGENTS"
    else
```

Note: `run_with_review` handles spawning, monitoring, and cleanup internally. The `failed` variable is unused in the Docker multi-round path (cleanup is via `cleanup_docker`).

- [ ] **Step 2: Verify the replacement is correct**

```bash
grep -n "run_with_review\|docker_wait_workers" swarm
```

Expected: `run_with_review` appears in `main()` and `cmd_resume()` (once each after all changes), `docker_wait_workers` appears only in `cmd_resume()` (single-round --no-docker fallback, which is unchanged).

Actually at this point `docker_wait_workers` should no longer appear in `main()`. Verify:

```bash
grep -n "docker_wait_workers" swarm
```

Expected: only in `cmd_resume` (it's called there for Docker single-round resume, which we update in Task 8).

- [ ] **Step 3: Commit**

```bash
git add swarm
git commit -m "feat: update main() to use run_with_review() for Docker runs"
```

---

### Task 8: Update `swarm.state` and `cmd_resume()` for multi-round

**Files:**
- Modify: `swarm`

Two changes needed:
1. `swarm.state` write in `main()` must include `SWARM_MULTI_ROUND`
2. `cmd_resume()` must skip the pending=0 early-exit and call `run_with_review()` when `SWARM_MULTI_ROUND=true`

- [ ] **Step 1: Add `SWARM_MULTI_ROUND` to the `swarm.state` write**

In `main()`, the `swarm.state` write block (lines 877–882) currently is:

```bash
    # Write state file so 'swarm resume' can restart this run
    {
        printf 'SWARM_TASK=%q\n' "$TASK"
        printf 'SWARM_AGENTS=%s\n' "$NUM_AGENTS"
        printf 'SWARM_DOCKER=%s\n' "$USE_DOCKER"
        printf 'SWARM_STARTED="%s"\n' "$(date)"
    } > "$OUTPUT_DIR/swarm.state"
```

Replace with:

```bash
    # Write state file so 'swarm resume' can restart this run
    local swarm_multi_round="false"
    if [[ "$USE_DOCKER" == "true" ]]; then swarm_multi_round="true"; fi
    {
        printf 'SWARM_TASK=%q\n' "$TASK"
        printf 'SWARM_AGENTS=%s\n' "$NUM_AGENTS"
        printf 'SWARM_DOCKER=%s\n' "$USE_DOCKER"
        printf 'SWARM_MULTI_ROUND=%s\n' "$swarm_multi_round"
        printf 'SWARM_STARTED="%s"\n' "$(date)"
    } > "$OUTPUT_DIR/swarm.state"
```

- [ ] **Step 2: Update `cmd_resume()` to source `SWARM_MULTI_ROUND` safely**

In `cmd_resume()`, line 280 currently sources the state file:

```bash
    source "$state_file"  # sets SWARM_TASK, SWARM_AGENTS, SWARM_DOCKER
```

The source already picks up `SWARM_MULTI_ROUND` from the file. Update the comment:

```bash
    source "$state_file"  # sets SWARM_TASK, SWARM_AGENTS, SWARM_DOCKER, SWARM_MULTI_ROUND
```

- [ ] **Step 3: Skip pending=0 early exit in `cmd_resume()` when MULTI_ROUND=true**

In `cmd_resume()`, lines 336–340 are:

```bash
    if [[ "$pending" -eq 0 ]]; then
        success "Nothing to resume — all tasks already complete ($done_n done)"
        info "Project files: $MAIN_DIR/"
        exit 0
    fi
```

Replace with:

```bash
    if [[ "$pending" -eq 0 && "${SWARM_MULTI_ROUND:-false}" != "true" ]]; then
        success "Nothing to resume — all tasks already complete ($done_n done)"
        info "Project files: $MAIN_DIR/"
        exit 0
    fi
```

- [ ] **Step 4: Update `cmd_resume()` Docker worker spawn to call `run_with_review()` when MULTI_ROUND**

In `cmd_resume()`, the Docker spawn block (lines 347–356) is:

```bash
    local failed=0
    if [[ "$USE_DOCKER" == "true" ]]; then
        RUN_ID="$(basename "$OUTPUT_DIR")"
        ensure_docker_image
        for i in $(seq 1 "$agents"); do
            docker_run_worker "$i"
            sleep 1
        done
        monitor_progress &
        local monitor_pid=$!
        failed=$(docker_wait_workers "$agents")
        kill "$monitor_pid" 2>/dev/null || true
    else
```

Replace with:

```bash
    local failed=0
    if [[ "$USE_DOCKER" == "true" ]]; then
        RUN_ID="$(basename "$OUTPUT_DIR")"
        ensure_docker_image
        trap cleanup_docker EXIT
        if [[ "${SWARM_MULTI_ROUND:-false}" == "true" ]]; then
            run_with_review "$agents"
        else
            for i in $(seq 1 "$agents"); do
                docker_run_worker "$i"
                sleep 1
            done
            monitor_progress &
            local monitor_pid=$!
            failed=$(docker_wait_workers "$agents")
            kill "$monitor_pid" 2>/dev/null || true
        fi
    else
```

- [ ] **Step 5: Verify SWARM_MULTI_ROUND appears in swarm.state write and cmd_resume**

```bash
grep -n "SWARM_MULTI_ROUND" swarm
```

Expected: lines in `main()` (state file write), `cmd_resume()` comment, `cmd_resume()` pending-check, and `cmd_resume()` dispatch.

- [ ] **Step 6: Commit**

```bash
git add swarm
git commit -m "feat: add SWARM_MULTI_ROUND to state file and update cmd_resume for multi-round"
```

---

## Chunk 3: End-to-End Verification

### Task 9: Run a test swarm and verify multi-round behavior

**Files:** none (verification only)

- [ ] **Step 1: Run a small test swarm with Docker**

```bash
cd /Users/dmatt/Claude\ Projects/swarm
./swarm "Build a Python script that prints a multiplication table for numbers 1-5" --agents 2 --output swarm-dev-$(date +%s)
```

This is a simple task that should complete in a few tasks. Watch for reviewer log files appearing.

- [ ] **Step 2: Verify reviewer logs were created**

```bash
ls swarm-dev-*/logs/reviewer-*.log 2>/dev/null | head -10
```

Expected: at least one `reviewer-N.log` file exists.

- [ ] **Step 3: Verify reviewer signals appear in logs**

```bash
grep -l "ALL_COMPLETE\|REVIEW_DONE" swarm-dev-*/logs/reviewer-*.log 2>/dev/null
```

Expected: at least one log file containing one of these signals.

- [ ] **Step 4: Verify workers did not self-exit prematurely (MULTI_ROUND check)**

```bash
grep "MULTI_ROUND\|DONE at\|MAXED OUT" swarm-dev-*/logs/worker-*.log 2>/dev/null | head -20
```

Expected: `DONE at` lines appear after `ALL_COMPLETE` was signaled (workers killed by harness, not self-exit).

- [ ] **Step 5: Verify the project was actually built**

```bash
ls swarm-dev-*/main/
cat swarm-dev-*/main/SPEC.md | head -20
```

- [ ] **Step 6: Test swarm resume on a multi-round run**

Stop a running swarm mid-way (use Ctrl-C or `./swarm kill`), then resume:

```bash
# Start a longer run
./swarm "Build a Python REST API with three endpoints: GET /items, POST /items, DELETE /items/:id using FastAPI and an in-memory list" --agents 2 --output swarm-dev-resume-$(date +%s)
# Hit Ctrl-C after a few tasks complete (check logs/ for done tasks)
# Then resume:
./swarm resume swarm-dev-resume-*/
```

Expected: resume continues from where it stopped, uses `run_with_review`, reviewer runs for tasks that were already done but not reviewed.

- [ ] **Step 7: Verify --no-docker mode is unaffected**

```bash
./swarm "Echo hello world to a file" --no-docker --output swarm-dev-nodock-$(date +%s) 2>&1 | head -30
```

Expected: runs without errors, no reviewer involvement, uses the old single-round path.

- [ ] **Step 8: Clean up dev swarms**

```bash
rm -rf swarm-dev-*/
```

- [ ] **Step 9: Final commit if any fixes were needed**

```bash
git add -A && git commit -m "fix: multi-round corrections from verification" 2>/dev/null || true
```
