# Swarm Testing Expansion & --no-docker Removal Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove bare-metal (`--no-docker`) execution mode and add comprehensive test coverage for task state machine, reviewer loop, resume, and status commands.

**Architecture:** All tests follow the existing pattern in `tests/helpers.sh`: source the swarm script, override docker functions as no-ops, manipulate a real bare git repo via `init_test_workspace`/`push_file_to_repo`, then assert on filesystem state and call tracking arrays. Every test mocks `docker_run_worker`, `docker_run_reviewer`, and related Docker calls — no real containers or Claude CLI calls are made.

**Tech Stack:** bash 5+, git, tests/helpers.sh (existing)

---

## Chunk 1: Remove `--no-docker` mode

**Files:**
- Modify: `swarm`
- Modify: `tests/test_cleanup.sh`
- Modify: `tests/helpers.sh`

### Task 1: Write a test asserting `--no-docker` is rejected

- [ ] **Step 1: Add a test to `tests/test_cleanup.sh`** (bottom, before `print_summary`)

```bash
# ─── Test 5: --no-docker flag produces "Unknown option" error ─────────────────

setup_test "no-docker: --no-docker flag produces unknown option error"
trap teardown_test EXIT

exit_code=0
output=$(bash "$SWARM_SCRIPT" --no-docker "test task" 2>&1) || exit_code=$?
[[ "$exit_code" -ne 0 ]] \
    && pass "--no-docker exits non-zero" \
    || fail "--no-docker should exit non-zero"
assert_output_contains "$output" "Unknown option" "--no-docker prints Unknown option error"

teardown_test
trap - EXIT
```

- [ ] **Step 2: Run the test, verify it fails (--no-docker is currently accepted)**

```bash
bash tests/test_cleanup.sh 2>&1 | tail -20
```
Expected: last test reports FAIL (--no-docker currently accepted with exit 0, no "Unknown option" message)

### Task 2: Remove `--no-docker` and all bare-metal code from `swarm`

Read `swarm` fully, then make all of the following changes:

- [ ] **Step 3: Remove `USE_DOCKER` default variable**

Delete line: `USE_DOCKER=true`

- [ ] **Step 4: Remove `--no-docker` from `usage()`**

Delete line: `  --no-docker           Run agents on host instead of in Docker containers`

- [ ] **Step 5: Remove `claude_run()` function** (only used by bare-metal workers)

Delete the entire `claude_run()` function (the one that calls `env -u CLAUDECODE claude`).

- [ ] **Step 6: Remove `run_orchestrator()` function** (bare-metal orchestrator)

Delete the entire `run_orchestrator()` function and its section header comment.

- [ ] **Step 7: Remove `run_worker()` function** (bare-metal worker)

Delete the entire `run_worker()` function and its section header comment.

- [ ] **Step 8: Simplify `cmd_status()` — remove `.pid` file branch**

In `cmd_status`, the worker status loop checks `.cid` then `.pid`. Remove the `elif [[ -f "$pid_file" ]]` branch entirely. After removal the block should be:

```bash
        if [[ -f "$cid_file" ]]; then
            local wcname
            wcname=$(cat "$cid_file" 2>/dev/null || echo "")
            if [[ -n "$wcname" ]] && docker inspect --format='{{.State.Running}}' "$wcname" 2>/dev/null | grep -q true; then
                wstatus="${GREEN}RUNNING (container)${NC}"
            else
                wstatus="${YELLOW}STOPPED${NC}"
            fi
        elif grep -q "DONE at" "$wlog" 2>/dev/null; then
```

Also remove the `local pid_file` declaration that is no longer used in this block.

- [ ] **Step 9: Simplify `cmd_kill()` — remove `.pid` file loop**

Delete the entire `# Kill all — PIDs` block (the `for pid_file in "$pids_dir"/*.pid` loop). Also remove the `.pid` branch in the single-target kill path (`elif [[ -f "$pid_file" ]]` block).

- [ ] **Step 10: Simplify `cmd_resume()` — remove bare-metal branch and SWARM_MULTI_ROUND early-exit**

a) Remove the line: `USE_DOCKER="${SWARM_DOCKER:-true}"` (no longer needed)

   Also update the comment on the `source "$state_file"` line above it from:
   `# sets SWARM_TASK, SWARM_AGENTS, SWARM_DOCKER, SWARM_MULTI_ROUND`
   to:
   `# sets SWARM_TASK, SWARM_AGENTS (SWARM_DOCKER/SWARM_MULTI_ROUND ignored if present in old state files)`

b) Remove the early-exit block that checks `SWARM_MULTI_ROUND`:
```bash
    if [[ "$pending" -eq 0 && "${SWARM_MULTI_ROUND:-false}" != "true" ]]; then
        success "Nothing to resume — all tasks already complete ($done_n done)"
        info "Project files: $MAIN_DIR/"
        exit 0
    fi
```

c) In the worker-spawning block at the bottom of `cmd_resume`, remove the `else` branch (bare-metal path). Keep only the `if [[ "$USE_DOCKER" == "true" ]]; then` body, then delete the entire `if/else` wrapper so Docker is unconditional:

```bash
    # Spawn workers
    local failed=0
    RUN_ID="$(basename "$OUTPUT_DIR")"
    ensure_docker_image
    trap cleanup_docker EXIT
    run_with_review "$agents"
```

- [ ] **Step 11: Simplify `main()` — remove `USE_DOCKER` checks and `SWARM_MULTI_ROUND` fork**

a) Remove the mode display line: `info "Mode:   bare-metal (--no-docker)"`

b) Remove the `else` branch of the Docker prerequisite check. Keep only:
```bash
    if ! command -v docker &>/dev/null; then
        error "Docker not found. Install Docker."
        exit 1
    fi
```

c) Remove the `SWARM_DOCKER` and `SWARM_MULTI_ROUND` lines from the state file write block. Change to:
```bash
    {
        printf 'SWARM_TASK=%q\n' "$TASK"
        printf 'SWARM_AGENTS=%s\n' "$NUM_AGENTS"
        printf 'SWARM_STARTED="%s"\n' "$(date)"
    } > "$OUTPUT_DIR/swarm.state"
```

d) In the orchestrator step, remove the entire `if/else` — keep only `docker_run_orchestrator`:
```bash
    if ! docker_run_orchestrator; then
        error "Orchestration failed."
        exit 1
    fi
```

e) In the worker spawning step, remove the entire `if/else` — keep only `run_with_review "$NUM_AGENTS"`. This is correct because `run_with_review` always uses Docker and handles the reviewer loop. The old non-review path (bare `docker_run_worker` loop) was for `--no-docker` state-compatible runs and is no longer needed.

f) In `main()`, remove the specialist pre-flight guard (`if [[ "$USE_DOCKER" == "true" ]]; then`) — pre-flight sweep is now unconditional.

- [ ] **Step 12: Remove `--no-docker` from argument parsing; let it fall to unknown-option error**

Remove both occurrences: `--no-docker) USE_DOCKER=false; shift ;;`
(One in the `resume` subcommand parser, one in the main `while` loop.)

After removal, `--no-docker` will fall to the `*) error "Unknown option: $1"; usage; exit 1 ;;` branch in the main parser, which is the desired behavior.

- [ ] **Step 13: Remove stale `USE_DOCKER=true` from `tests/helpers.sh`**

In `tests/helpers.sh`, remove the line `USE_DOCKER=true` from the `load_swarm()` function. After this removal the variable is gone from both production code and test infrastructure.

- [ ] **Step 14: Verify the test now passes**

```bash
bash tests/test_cleanup.sh 2>&1 | tail -20
```
Expected: all 5 tests pass

- [ ] **Step 15: Run full test suite**

```bash
bash tests/run_tests.sh
```
Expected: all suites pass

- [ ] **Step 16: Commit**

```bash
git add swarm tests/test_cleanup.sh tests/helpers.sh
git commit -m "refactor: remove --no-docker bare-metal execution mode"
```

---

## Chunk 2: Task state machine tests

**Files:**
- Create: `tests/test_task_state_machine.sh`

### Task 3: Write and verify task state machine tests

These tests verify the git-level coordination protocol: file counting helpers, sync, task ordering, and push rejection on concurrent claims.

- [ ] **Step 1: Create `tests/test_task_state_machine.sh`**

```bash
#!/usr/bin/env bash
# Integration tests for the git-based task state machine.
# No Docker or Claude needed — tests git coordination directly.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ─── Test 1: pending_count() returns correct count ───────────────────────────

setup_test "state machine: pending_count() returns correct count"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task 1"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002" "add task 2"

load_swarm

result=$(pending_count)
assert_eq "2" "$result" "pending_count returns 2"

teardown_test
trap - EXIT

# ─── Test 2: active_count() returns correct count ────────────────────────────

setup_test "state machine: active_count() returns correct count"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/active/worker-1--001-setup.md" "# Task 001" "w1: claim"
push_file_to_repo "tasks/active/worker-2--002-build.md" "# Task 002" "w2: claim"

load_swarm

result=$(active_count)
assert_eq "2" "$result" "active_count returns 2"

teardown_test
trap - EXIT

# ─── Test 3: done_count() returns correct count ──────────────────────────────

setup_test "state machine: done_count() returns correct count"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md"  "# Task 001" "done 1"
push_file_to_repo "tasks/done/002-build.md"  "# Task 002" "done 2"
push_file_to_repo "tasks/done/003-deploy.md" "# Task 003" "done 3"

load_swarm

result=$(done_count)
assert_eq "3" "$result" "done_count returns 3"

teardown_test
trap - EXIT

# ─── Test 4: sync_main() pulls latest commits from bare repo ─────────────────

setup_test "state machine: sync_main() pulls latest state from repo"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Push a file directly to the bare repo, bypassing the MAIN_DIR pull
tmp=$(mktemp -d)
git clone "$REPO_DIR" "$tmp" -q 2>/dev/null
(
    cd "$tmp"
    git config user.email "test@swarm"
    git config user.name "Test"
    mkdir -p tasks/done
    printf '# Task 001\n' > tasks/done/001-setup.md
    git add -A
    git commit -m "done 001" -q
    git push origin main -q
)
rm -rf "$tmp"

assert_file_not_exists "$MAIN_DIR/tasks/done/001-setup.md" "file not yet in MAIN_DIR"

sync_main

assert_file_exists "$MAIN_DIR/tasks/done/001-setup.md" "file visible after sync_main"

teardown_test
trap - EXIT

# ─── Test 5: Lowest-numbered task is listed first ────────────────────────────

setup_test "state machine: lowest-numbered task appears first in ls order"
trap teardown_test EXIT

init_test_workspace
# Push out of order to confirm sort is by name not insertion order
push_file_to_repo "tasks/pending/003-deploy.md" "# Task 003" "add 003"
push_file_to_repo "tasks/pending/001-setup.md"  "# Task 001" "add 001"
push_file_to_repo "tasks/pending/002-build.md"  "# Task 002" "add 002"

load_swarm

first_task=$(ls "$MAIN_DIR/tasks/pending/"*.md 2>/dev/null \
    | grep -v '\.gitkeep' | head -1 | xargs basename)
assert_eq "001-setup.md" "$first_task" "001-setup.md is first in ls order"

teardown_test
trap - EXIT

# ─── Test 6: Concurrent claim push is rejected (race condition) ──────────────

setup_test "state machine: second concurrent task claim push is rejected"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

# Two workers clone from the same commit
w1=$(mktemp -d)
w2=$(mktemp -d)
git clone "$REPO_DIR" "$w1" -q 2>/dev/null
git clone "$REPO_DIR" "$w2" -q 2>/dev/null
git -C "$w1" config user.email "w1@swarm"; git -C "$w1" config user.name "Worker1"
git -C "$w2" config user.email "w2@swarm"; git -C "$w2" config user.name "Worker2"

# Worker 1 claims task and pushes successfully
(
    cd "$w1"
    mv tasks/pending/001-setup.md tasks/active/worker-1--001-setup.md
    git add -A
    git commit -m "w1: claim 001" -q
    git push origin main -q
)

# Worker 2 tries to claim same task from stale clone (same parent commit)
(
    cd "$w2"
    mv tasks/pending/001-setup.md tasks/active/worker-2--001-setup.md
    git add -A
    git commit -m "w2: claim 001" -q
) 2>/dev/null

push_exit=0
(cd "$w2" && git push origin main 2>/dev/null) || push_exit=$?

[[ "$push_exit" -ne 0 ]] \
    && pass "second push correctly rejected (non-fast-forward)" \
    || fail "second push should be rejected"

# After pulling, worker 2 can see worker 1 owns the task
(cd "$w2" && git fetch origin main -q 2>/dev/null) || true
w2_refs=$(git -C "$w2" ls-tree origin/main --name-only tasks/active/ 2>/dev/null || true)
echo "$w2_refs" | grep -q "worker-1--001-setup.md" \
    && pass "worker-1 claim visible after fetch" \
    || fail "worker-1 claim not visible"

rm -rf "$w1" "$w2"

teardown_test
trap - EXIT

print_summary
```

- [ ] **Step 2: Make executable and run**

```bash
chmod +x tests/test_task_state_machine.sh
bash tests/test_task_state_machine.sh
```
Expected: all 6 tests pass

- [ ] **Step 3: Run full suite**

```bash
bash tests/run_tests.sh
```
Expected: all suites pass

- [ ] **Step 4: Commit**

```bash
git add tests/test_task_state_machine.sh
git commit -m "test: add task state machine tests (pending/active/done counts, sync, ordering, race)"
```

---

## Chunk 3: Reviewer loop tests (signals, stuck detection, final drain)

**Files:**
- Create: `tests/test_reviewer_loop.sh`

### Task 4: Write and verify reviewer loop tests

These tests exercise `run_with_review` with all Docker functions mocked. The loop is driven by real filesystem state in MAIN_DIR. `sleep` is overridden to a no-op so tests run fast.

- [ ] **Step 1: Create `tests/test_reviewer_loop.sh`**

```bash
#!/usr/bin/env bash
# Integration tests for the run_with_review review loop.
# All Docker calls mocked. sleep() overridden to no-op for fast tests.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# Shared mock setup — call after load_swarm in each test
setup_review_mocks() {
    # Prevent real Docker calls
    docker_run_worker()              { :; }
    monitor_progress()               { :; }
    cleanup_docker()                 { :; }
    check_and_respawn_dead_workers() { :; }
    run_specialist_sweep()           { :; }
    # Override sleep builtin to avoid delays
    sleep()                          { :; }
    # sync_main is a no-op: MAIN_DIR is pre-populated by push_file_to_repo
    # (which already pulls). Mocking prevents git pull from reverting any
    # in-test filesystem mutations made by docker_run_reviewer mocks.
    sync_main()                      { :; }
    # Prevent specialist sweeps from firing on low done counts
    SPECIALIST_EARLY_SWEEP=999
    SPECIALIST_INTERVAL=999
    # Small limit so infinite-loop bugs surface quickly (max_reviews = 5 * agents)
    MAX_WORKER_ITERATIONS=5
}

# ─── Test 1: ALL_COMPLETE in reviewer log terminates the loop ─────────────────

setup_test "reviewer loop: ALL_COMPLETE terminates the loop"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm
setup_review_mocks

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

assert_eq "1" "${#REVIEWER_CALLS[@]}" "reviewer called exactly once"
assert_eq "001-setup.md" "${REVIEWER_CALLS[0]}" "reviewer called for done task"

teardown_test
trap - EXIT

# ─── Test 2: REVIEW_DONE continues loop; second done task is also reviewed ────

setup_test "reviewer loop: REVIEW_DONE continues loop to next task"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done 1"
push_file_to_repo "tasks/done/002-build.md"  "# Task 002" "done 2"

load_swarm
setup_review_mocks

REVIEWER_CALLS=()
call_num=0
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    call_num=$((call_num + 1))
    mkdir -p "$LOGS_DIR"
    if [[ "$call_num" -lt 2 ]]; then
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

assert_eq "2" "${#REVIEWER_CALLS[@]}" "both tasks reviewed"

teardown_test
trap - EXIT

# ─── Test 3: Final drain reviewer fired when queue fully empty ────────────────

setup_test "reviewer loop: --final-- reviewer fired when pending and active are empty"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm
setup_review_mocks

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# Expect: 001-setup.md reviewed first, then --final-- drain
assert_eq "2" "${#REVIEWER_CALLS[@]}" "reviewer called twice"
assert_eq "--final--" "${REVIEWER_CALLS[1]}" "second call is --final-- drain"

teardown_test
trap - EXIT

# ─── Test 4: Stuck reviewer fired after 3 idle cycles ────────────────────────

setup_test "reviewer loop: --stuck-- reviewer fired after 3 idle cycles"
trap teardown_test EXIT

init_test_workspace
# One done task (will be reviewed once), one pending task that never completes
push_file_to_repo "tasks/done/001-setup.md"   "# Task 001" "done"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002" "pending"

load_swarm
setup_review_mocks

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--stuck--" ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# Verify --stuck-- was called (and that there were at least 2 calls:
# one for the initial done task review, one for --stuck--)
found_stuck=false
for call in "${REVIEWER_CALLS[@]+"${REVIEWER_CALLS[@]}"}"; do
    [[ "$call" == "--stuck--" ]] && found_stuck=true && break
done
[[ "$found_stuck" == "true" ]] \
    && pass "--stuck-- reviewer was called after idle cycles" \
    || fail "--stuck-- reviewer was not called"
[[ "${#REVIEWER_CALLS[@]}" -ge 2 ]] \
    && pass "at least 2 reviewer calls (initial review + stuck)" \
    || fail "expected at least 2 reviewer calls, got ${#REVIEWER_CALLS[@]}"

teardown_test
trap - EXIT

# ─── Test 5: Stuck counter resets when a new task completes ──────────────────

setup_test "reviewer loop: stuck counter resets when a new done task appears"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md"   "# Task 001" "done"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002" "pending"

load_swarm
setup_review_mocks

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "001-setup.md" ]]; then
        # Simulate 002 completing while 001 is being reviewed
        rm -f "$MAIN_DIR/tasks/pending/002-build.md"
        mkdir -p "$MAIN_DIR/tasks/done"
        printf '# Task 002\n' > "$MAIN_DIR/tasks/done/002-build.md"
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    elif [[ "$1" == "002-build.md" ]]; then
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    elif [[ "$1" == "--final--" ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    else
        # Unexpected call (--stuck--) → still terminate
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# --stuck-- should NOT have been called since new work appeared
found_stuck=false
for call in "${REVIEWER_CALLS[@]+"${REVIEWER_CALLS[@]}"}"; do
    [[ "$call" == "--stuck--" ]] && found_stuck=true && break
done
[[ "$found_stuck" == "false" ]] \
    && pass "--stuck-- not called when new work appeared" \
    || fail "--stuck-- called despite new work appearing (counter did not reset)"

# Final drain should have been called
found_final=false
for call in "${REVIEWER_CALLS[@]+"${REVIEWER_CALLS[@]}"}"; do
    [[ "$call" == "--final--" ]] && found_final=true && break
done
[[ "$found_final" == "true" ]] \
    && pass "--final-- drain was called after all work completed" \
    || fail "--final-- drain not called"

teardown_test
trap - EXIT

print_summary
```

- [ ] **Step 2: Make executable and run**

```bash
chmod +x tests/test_reviewer_loop.sh
bash tests/test_reviewer_loop.sh
```
Expected: all 5 tests pass

- [ ] **Step 3: Run full suite**

```bash
bash tests/run_tests.sh
```
Expected: all suites pass

- [ ] **Step 4: Commit**

```bash
git add tests/test_reviewer_loop.sh
git commit -m "test: add reviewer loop tests (ALL_COMPLETE, REVIEW_DONE, final drain, stuck detection)"
```

---

## Chunk 4: Resume and status tests

**Files:**
- Create: `tests/test_resume.sh`
- Create: `tests/test_status.sh`

### Task 5: Write and verify resume tests

`cmd_resume` reads `swarm.state`, returns active tasks to pending via a git commit, then spawns workers. Tests mock `run_with_review`, `ensure_docker_image`, `cleanup_docker`, and `run_specialist_sweep` to avoid real Docker calls.

- [ ] **Step 1: Create `tests/test_resume.sh`**

```bash
#!/usr/bin/env bash
# Integration tests for cmd_resume.
# No Docker or Claude needed — mocks run_with_review and docker helpers.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# Write a minimal swarm.state file for resume tests.
# SWARM_MULTI_ROUND=true is required so cmd_resume takes the run_with_review
# path rather than the bare-metal docker_run_worker loop (pre-Chunk-1 code).
# After Chunk 1 removes that conditional this is still harmless.
write_state_file() {
    local task="${1:-test task}"
    local agents="${2:-1}"
    cat > "$OUTPUT_DIR/swarm.state" <<EOF
SWARM_TASK=$(printf '%q' "$task")
SWARM_AGENTS=$agents
SWARM_MULTI_ROUND=true
SWARM_STARTED="$(date)"
EOF
}

# ─── Test 1: Active tasks are returned to pending on resume ───────────────────

setup_test "resume: active tasks returned to pending"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo \
    "tasks/active/worker-1--001-setup.md" \
    "# Task 001" \
    "w1: claim 001"
write_state_file "build a thing" 1

load_swarm

# Mock spawning-related functions
ensure_docker_image()  { :; }
cleanup_docker()       { :; }
run_with_review()      { :; }
run_specialist_sweep() { :; }
docker_run_worker()    { :; }
docker_wait_workers()  { echo 0; }
monitor_progress()     { :; }

cmd_resume "$OUTPUT_DIR"

# Pull to observe committed state
(cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true

assert_file_exists     "$MAIN_DIR/tasks/pending/001-setup.md"           "task returned to pending"
assert_file_not_exists "$MAIN_DIR/tasks/active/worker-1--001-setup.md"  "task removed from active"

teardown_test
trap - EXIT

# ─── Test 2: Multiple active tasks all returned to pending ────────────────────

setup_test "resume: multiple active tasks all returned to pending"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/active/worker-1--001-setup.md"  "# 001" "w1: claim 001"
push_file_to_repo "tasks/active/worker-2--002-build.md"  "# 002" "w2: claim 002"
push_file_to_repo "tasks/active/worker-3--003-deploy.md" "# 003" "w3: claim 003"
write_state_file "build a thing" 3

load_swarm

ensure_docker_image()  { :; }
cleanup_docker()       { :; }
run_with_review()      { :; }
run_specialist_sweep() { :; }
docker_run_worker()    { :; }
docker_wait_workers()  { echo 0; }
monitor_progress()     { :; }

cmd_resume "$OUTPUT_DIR"

(cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true

assert_file_exists "$MAIN_DIR/tasks/pending/001-setup.md"  "001 returned to pending"
assert_file_exists "$MAIN_DIR/tasks/pending/002-build.md"  "002 returned to pending"
assert_file_exists "$MAIN_DIR/tasks/pending/003-deploy.md" "003 returned to pending"
assert_file_not_exists "$MAIN_DIR/tasks/active/worker-1--001-setup.md"  "001 removed from active"
assert_file_not_exists "$MAIN_DIR/tasks/active/worker-2--002-build.md"  "002 removed from active"
assert_file_not_exists "$MAIN_DIR/tasks/active/worker-3--003-deploy.md" "003 removed from active"

teardown_test
trap - EXIT

# ─── Test 3: SWARM_AGENTS from state file passed to run_with_review ──────────

setup_test "resume: SWARM_AGENTS from state file used as agent count"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
write_state_file "build a thing" 4

load_swarm

ensure_docker_image()  { :; }
cleanup_docker()       { :; }
run_specialist_sweep() { :; }
docker_run_worker()    { :; }
docker_wait_workers()  { echo 0; }
monitor_progress()     { :; }

CAPTURED_AGENTS=""
run_with_review() { CAPTURED_AGENTS="$1"; }

cmd_resume "$OUTPUT_DIR"

assert_eq "4" "$CAPTURED_AGENTS" "run_with_review called with SWARM_AGENTS=4"

teardown_test
trap - EXIT

# ─── Test 4: -n N overrides SWARM_AGENTS ─────────────────────────────────────

setup_test "resume: -n N argument overrides SWARM_AGENTS from state file"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
write_state_file "build a thing" 2

load_swarm

ensure_docker_image()  { :; }
cleanup_docker()       { :; }
run_specialist_sweep() { :; }
docker_run_worker()    { :; }
docker_wait_workers()  { echo 0; }
monitor_progress()     { :; }

CAPTURED_AGENTS=""
run_with_review() { CAPTURED_AGENTS="$1"; }

cmd_resume "$OUTPUT_DIR" "7"

assert_eq "7" "$CAPTURED_AGENTS" "-n 7 overrides SWARM_AGENTS=2"

teardown_test
trap - EXIT

# ─── Test 5: No active tasks — resume runs without crashing ──────────────────

setup_test "resume: succeeds when there are no stuck active tasks"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
write_state_file "build a thing" 1

load_swarm

ensure_docker_image()  { :; }
cleanup_docker()       { :; }
run_specialist_sweep() { :; }
docker_run_worker()    { :; }
docker_wait_workers()  { echo 0; }
monitor_progress()     { :; }

RUN_CALLED=false
run_with_review() { RUN_CALLED=true; }

cmd_resume "$OUTPUT_DIR"

[[ "$RUN_CALLED" == "true" ]] \
    && pass "run_with_review called even when no stuck tasks" \
    || fail "run_with_review not called"

teardown_test
trap - EXIT

print_summary
```

- [ ] **Step 2: Make executable and run**

```bash
chmod +x tests/test_resume.sh
bash tests/test_resume.sh
```
Expected: all 5 tests pass

- [ ] **Step 3: Run full suite**

```bash
bash tests/run_tests.sh
```
Expected: all suites pass

- [ ] **Step 4: Commit**

```bash
git add tests/test_resume.sh
git commit -m "test: add cmd_resume tests (unstick tasks, state file, agent count override)"
```

### Task 6: Write and verify status tests

`cmd_status` reads task counts from the filesystem, displays worker status from `.cid` files and log files, and shows active/done task lists. Tests use a real git workspace; Docker calls are avoided by not creating `.cid` files.

- [ ] **Step 1: Create `tests/test_status.sh`**

```bash
#!/usr/bin/env bash
# Integration tests for cmd_status.
# Uses real git workspace. No Docker needed — avoids .cid files,
# uses log files for worker status instead.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# Strip ANSI color codes from output for assertion-friendly text
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ─── Test 1: Correct task counts displayed ────────────────────────────────────

setup_test "status: correct pending / active / done counts"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md"              "# 001" "add"
push_file_to_repo "tasks/pending/002-build.md"              "# 002" "add"
push_file_to_repo "tasks/active/worker-1--003-deploy.md"    "# 003" "claim"
push_file_to_repo "tasks/done/004-init.md"                  "# 004" "done"

load_swarm

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "2 pending" "2 pending shown"
assert_output_contains "$output" "1 active"  "1 active shown"
assert_output_contains "$output" "1 done"    "1 done shown"

teardown_test
trap - EXIT

# ─── Test 2: Active task listed with worker assignment ────────────────────────

setup_test "status: active task shown with worker name"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/active/worker-2--005-migrate.md" "# 005" "w2: claim"

load_swarm

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "worker-2"        "worker-2 shown in active tasks"
assert_output_contains "$output" "005-migrate.md"  "task name shown"

teardown_test
trap - EXIT

# ─── Test 3: Done tasks listed ───────────────────────────────────────────────

setup_test "status: done tasks listed by filename"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# 001" "done"
push_file_to_repo "tasks/done/002-build.md" "# 002" "done"

load_swarm

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "001-setup.md" "001-setup.md in done list"
assert_output_contains "$output" "002-build.md" "002-build.md in done list"

teardown_test
trap - EXIT

# ─── Test 4: Task description read from SPEC.md ──────────────────────────────

setup_test "status: task description from SPEC.md displayed"
trap teardown_test EXIT

init_test_workspace

# Update SPEC.md with a real task description
tmp=$(mktemp -d)
git clone "$REPO_DIR" "$tmp" -q 2>/dev/null
(
    cd "$tmp"
    git config user.email "test@swarm"
    git config user.name "Test"
    printf '# Project Specification\n\n**Task:** build a rocket ship\n' > SPEC.md
    git add SPEC.md
    git commit -m "update spec" -q
    git push origin main -q
)
rm -rf "$tmp"
(cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true

load_swarm

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "build a rocket ship" "task description from SPEC.md shown"

teardown_test
trap - EXIT

# ─── Test 5: Worker log "DONE at" shows DONE status ──────────────────────────

setup_test "status: worker with DONE log shows DONE status"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Create a worker log indicating completion (no .cid file — worker exited cleanly)
mkdir -p "$LOGS_DIR"
printf '=== Worker 1 started\n=== Worker 1 DONE at Thu Jan 1 00:00:00 UTC 2026 ===\n' \
    > "$LOGS_DIR/worker-1.log"

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "DONE" "DONE status shown for completed worker"

teardown_test
trap - EXIT

print_summary
```

- [ ] **Step 2: Make executable and run**

```bash
chmod +x tests/test_status.sh
bash tests/test_status.sh
```
Expected: all 5 tests pass

- [ ] **Step 3: Run full suite**

```bash
bash tests/run_tests.sh
```
Expected: all 4 new suites + existing 3 suites pass (7 total)

- [ ] **Step 4: Commit**

```bash
git add tests/test_status.sh
git commit -m "test: add cmd_status tests (counts, active tasks, done list, SPEC.md description)"
```
