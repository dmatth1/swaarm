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
    docker_run_orchestrator()        { :; }
    # Override sleep builtin to avoid delays
    sleep()                          { :; }
    # sync_main is a no-op: MAIN_DIR is pre-populated by push_file_to_repo
    # (which already pulls). Mocking prevents git pull from reverting any
    # in-test filesystem mutations made by docker_run_reviewer mocks.
    sync_main()                      { :; }
    # Prevent periodic restructuring from firing during tests (unless explicitly lowered)
    RESTRUCTURE_INTERVAL=999
    # Small limit so infinite-loop bugs surface quickly (max_reviews = 5 * agents)
    MAX_WORKER_ITERATIONS=5
}

# ─── Test 1: TESTS_PASS from regular reviewer does not exit; --final-- drain does

setup_test "reviewer loop: TESTS_PASS from regular reviewer defers to --final-- drain"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm
setup_review_mocks

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    # Per-task reviewer signals TESTS_PASS — loop should NOT terminate here;
    # it must proceed to final specialist sweep + --final-- drain reviewer.
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

# Expect: regular review of 001-setup.md, THEN --final-- drain
assert_eq "2" "${#REVIEWER_CALLS[@]}" "reviewer called twice (regular + final drain)"
assert_eq "001-setup.md" "${REVIEWER_CALLS[0]}" "first call reviews the done task"
assert_eq "--final--" "${REVIEWER_CALLS[1]}" "second call is --final-- drain"

teardown_test
trap - EXIT

# ─── Test 2: TESTS_PASS continues loop; second done task is also reviewed ─────

setup_test "reviewer loop: TESTS_PASS continues loop to next task"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done 1"
push_file_to_repo "tasks/done/002-build.md"  "# Task 002" "done 2"

load_swarm
setup_review_mocks

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

# Expect: both done tasks reviewed, then --final-- drain
assert_eq "3" "${#REVIEWER_CALLS[@]}" "both tasks reviewed plus final drain"
assert_eq "001-setup.md" "${REVIEWER_CALLS[0]}" "first task reviewed"
assert_eq "002-build.md" "${REVIEWER_CALLS[1]}" "second task reviewed"
assert_eq "--final--" "${REVIEWER_CALLS[2]}" "final drain after both reviewed"

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
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

# Expect: 001-setup.md reviewed first, then --final-- drain
assert_eq "2" "${#REVIEWER_CALLS[@]}" "reviewer called twice"
assert_eq "--final--" "${REVIEWER_CALLS[1]}" "second call is --final-- drain"

teardown_test
trap - EXIT

# ─── Test 4: Stuck orchestrator fired after 3 idle cycles ────────────────────

setup_test "reviewer loop: orchestrator fired after 3 idle cycles (stuck state)"
trap teardown_test EXIT

init_test_workspace
# One done task (will be reviewed once), one pending task that never completes
push_file_to_repo "tasks/done/001-setup.md"   "# Task 001" "done"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002" "pending"

load_swarm
setup_review_mocks

ORCHESTRATOR_CALLS=()
docker_run_orchestrator() {
    ORCHESTRATOR_CALLS+=("stuck")
    # Resolve the stuck state by moving the pending task to done
    # so the loop can proceed to final drain
    mkdir -p "$MAIN_DIR/tasks/done"
    mv "$MAIN_DIR/tasks/pending/002-build.md" "$MAIN_DIR/tasks/done/002-build.md" 2>/dev/null || true
}

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

# Verify orchestrator was called to resolve the stuck state
found_stuck=false
for call in "${ORCHESTRATOR_CALLS[@]+"${ORCHESTRATOR_CALLS[@]}"}"; do
    [[ "$call" == "stuck" ]] && found_stuck=true && break
done
[[ "$found_stuck" == "true" ]] \
    && pass "orchestrator was called after idle cycles (stuck state)" \
    || fail "orchestrator was not called for stuck state"
[[ "${#REVIEWER_CALLS[@]}" -ge 1 ]] \
    && pass "at least 1 reviewer call (initial review)" \
    || fail "expected at least 1 reviewer call, got ${#REVIEWER_CALLS[@]}"

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

ORCHESTRATOR_CALLS=()
docker_run_orchestrator() {
    ORCHESTRATOR_CALLS+=("stuck")
}

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "001-setup.md" ]]; then
        # Simulate 002 completing while 001 is being reviewed
        rm -f "$MAIN_DIR/tasks/pending/002-build.md"
        mkdir -p "$MAIN_DIR/tasks/done"
        printf '# Task 002\n' > "$MAIN_DIR/tasks/done/002-build.md"
    fi
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

# Orchestrator should NOT have been called since new work appeared
found_stuck=false
for call in "${ORCHESTRATOR_CALLS[@]+"${ORCHESTRATOR_CALLS[@]}"}"; do
    [[ "$call" == "stuck" ]] && found_stuck=true && break
done
[[ "$found_stuck" == "false" ]] \
    && pass "orchestrator not called when new work appeared (stuck counter reset)" \
    || fail "orchestrator called despite new work appearing (counter did not reset)"

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

# ─── Test 6: Blocked task handled by orchestrator, then final drain fires ────

setup_test "reviewer loop: blocked task handled by orchestrator, final drain still fires"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"
push_file_to_repo "tasks/pending/BLOCKED-002-build.md" "# Task 002 blocked" "blocked"

load_swarm
setup_review_mocks

ORCHESTRATOR_CALLS=()
docker_run_orchestrator() {
    ORCHESTRATOR_CALLS+=("blocked")
    # Simulate orchestrator resolving the blocked task (moves it to done)
    rm -f "$MAIN_DIR/tasks/pending/BLOCKED-002-build.md"
    mkdir -p "$MAIN_DIR/tasks/done"
    printf '# Task 002\n' > "$MAIN_DIR/tasks/done/002-build.md"
}

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

# Verify orchestrator was called for the blocked task
found_blocked=false
for call in "${ORCHESTRATOR_CALLS[@]+"${ORCHESTRATOR_CALLS[@]}"}"; do
    [[ "$call" == "blocked" ]] && found_blocked=true && break
done
[[ "$found_blocked" == "true" ]] \
    && pass "orchestrator called to handle blocked task" \
    || fail "orchestrator not called for blocked task"

# Verify --final-- drain was reached
found_final=false
for call in "${REVIEWER_CALLS[@]+"${REVIEWER_CALLS[@]}"}"; do
    [[ "$call" == "--final--" ]] && found_final=true && break
done
[[ "$found_final" == "true" ]] \
    && pass "--final-- drain reached after blocked task resolved" \
    || fail "--final-- drain not reached"

teardown_test
trap - EXIT

# ─── Test 7: Final specialist sweep runs before --final-- drain ──────────────

setup_test "reviewer loop: final specialist sweep runs before --final-- drain"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm
setup_review_mocks

SPECIALIST_SWEEPS=()
run_specialist_sweep() {
    SPECIALIST_SWEEPS+=("$1")
}

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

# Verify final specialist sweep ran
found_final_sweep=false
for sweep in "${SPECIALIST_SWEEPS[@]+"${SPECIALIST_SWEEPS[@]}"}"; do
    [[ "$sweep" == "final" ]] && found_final_sweep=true && break
done
[[ "$found_final_sweep" == "true" ]] \
    && pass "final specialist sweep ran before --final-- drain" \
    || fail "final specialist sweep did not run"

# Verify --final-- drain reviewer ran after sweep
last_idx=$(( ${#REVIEWER_CALLS[@]} - 1 ))
assert_eq "--final--" "${REVIEWER_CALLS[$last_idx]}" "last reviewer call is --final-- drain"

teardown_test
trap - EXIT

# ─── Test 8: Specialist sweep runs specialists in parallel ────────────────────

setup_test "reviewer loop: specialist sweep runs all specialists in parallel"
trap teardown_test EXIT

init_test_workspace

# Create a SPEC.md with 3 specialists
push_file_to_repo "SPEC.md" "$(cat <<'SPECEOF'
# Test Spec
**Task:** test

## Success Criteria
- [ ] pass

## Specialists

### SecurityExpert
Review code for vulnerabilities

### PerformanceEngineer
Optimize hot paths

### QAEngineer
Verify test coverage
SPECEOF
)" "add spec with specialists"

push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm
# Don't use setup_review_mocks — we want the real run_specialist_sweep
docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
docker_run_orchestrator()        { :; }
sleep()                          { :; }
sync_main()                      { :; }

# Track specialist calls
SPECIALIST_CALLS_FILE="$TEST_TMPDIR/specialist_calls"
docker_run_specialist() {
    echo "$1" >> "$SPECIALIST_CALLS_FILE"
}

_g_specialist_count=0
run_specialist_sweep "test"

# Verify all 3 specialists were called
if [[ -f "$SPECIALIST_CALLS_FILE" ]]; then
    call_count=$(wc -l < "$SPECIALIST_CALLS_FILE" | tr -d ' ')
    [[ "$call_count" -eq 3 ]] \
        && pass "all 3 specialists ran ($call_count calls)" \
        || fail "expected 3 specialist calls, got $call_count"

    grep -q "SecurityExpert" "$SPECIALIST_CALLS_FILE" \
        && pass "SecurityExpert was called" \
        || fail "SecurityExpert not called"

    grep -q "PerformanceEngineer" "$SPECIALIST_CALLS_FILE" \
        && pass "PerformanceEngineer was called" \
        || fail "PerformanceEngineer not called"

    grep -q "QAEngineer" "$SPECIALIST_CALLS_FILE" \
        && pass "QAEngineer was called" \
        || fail "QAEngineer not called"
else
    fail "no specialist calls recorded"
    fail "SecurityExpert not called"
    fail "PerformanceEngineer not called"
    fail "QAEngineer not called"
fi

teardown_test
trap - EXIT

# ─── Test: Stuck detection fires when done_count = 0 ──────────────────────────

setup_test "reviewer loop: stuck detection fires with pending > 0, active = 0, done = 0"
trap teardown_test EXIT

init_test_workspace
# Only pending tasks, nothing done yet — simulates workers crashing before completing any task
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "pending"

load_swarm
setup_review_mocks

ORCHESTRATOR_CALLS=()
docker_run_orchestrator() {
    ORCHESTRATOR_CALLS+=("stuck")
    # Resolve by moving the pending task to done
    mkdir -p "$MAIN_DIR/tasks/done"
    mv "$MAIN_DIR/tasks/pending/001-setup.md" "$MAIN_DIR/tasks/done/001-setup.md" 2>/dev/null || true
}

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

found_stuck=false
for call in "${ORCHESTRATOR_CALLS[@]+"${ORCHESTRATOR_CALLS[@]}"}"; do
    [[ "$call" == "stuck" ]] && found_stuck=true && break
done
[[ "$found_stuck" == "true" ]] \
    && pass "orchestrator fired with done_count=0 (stuck detection no longer requires done > 0)" \
    || fail "orchestrator not called — stuck detection still blocked by done_count=0 guard"

teardown_test
trap - EXIT

# ─── Test: Respawn counter caps at MAX_RESPAWNS ──────────────────────────────

setup_test "reviewer loop: respawn counter prevents infinite respawn loops"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "pending"

load_swarm
# Don't use setup_review_mocks — we need real check_and_respawn_dead_workers
docker_run_reviewer()    { :; }
monitor_progress()       { :; }
cleanup_docker()         { :; }
run_specialist_sweep()   { :; }
docker_run_orchestrator() {
    # Resolve stuck state so loop can exit
    mkdir -p "$MAIN_DIR/tasks/done"
    mv "$MAIN_DIR/tasks/pending/001-setup.md" "$MAIN_DIR/tasks/done/001-setup.md" 2>/dev/null || true
}
sleep()                  { :; }
sync_main()              { :; }

# Simulate a dead worker by writing a .cid file for a non-existent container
mkdir -p "$OUTPUT_DIR/pids"
echo "swarm-test-dead-worker" > "$OUTPUT_DIR/pids/worker-1.cid"
docker() {
    if [[ "$1" == "inspect" ]]; then
        return 1  # container not found
    elif [[ "$1" == "rm" ]]; then
        return 0
    elif [[ "$1" == "run" ]]; then
        # Simulate worker dying again immediately — recreate the cid file
        echo "swarm-test-dead-worker" > "$OUTPUT_DIR/pids/worker-1.cid"
        return 0
    fi
}
docker_run_worker() {
    # Simulate spawning a worker that immediately dies
    echo "swarm-test-dead-worker" > "$OUTPUT_DIR/pids/worker-1.cid"
}

# Set low cap for testing
MAX_RESPAWNS=3

# Run check_and_respawn_dead_workers repeatedly
local_respawn_count=0
for attempt in 1 2 3 4 5; do
    check_and_respawn_dead_workers 1
    if [[ -f "$OUTPUT_DIR/pids/worker-1.respawns" ]]; then
        local_respawn_count=$(cat "$OUTPUT_DIR/pids/worker-1.respawns")
    fi
done

[[ "$local_respawn_count" -le 3 ]] \
    && pass "respawn capped at MAX_RESPAWNS=3 (count=$local_respawn_count)" \
    || fail "respawn exceeded cap: $local_respawn_count > 3"

teardown_test
trap - EXIT

# ─── Test: Respawn counter resets on progress ─────────────────────────────────

setup_test "reviewer loop: respawn counter resets when tasks complete"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm
setup_review_mocks

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

# Pre-create a respawn counter file (simulating prior crashes)
mkdir -p "$OUTPUT_DIR/pids"
echo "2" > "$OUTPUT_DIR/pids/worker-1.respawns"

run_with_review 1

# After a task was reviewed (progress made), respawn counter should be cleared
if [[ -f "$OUTPUT_DIR/pids/worker-1.respawns" ]]; then
    fail "respawn counter not cleared after task completion"
else
    pass "respawn counter cleared after task completion (progress resets cap)"
fi

teardown_test
trap - EXIT

# ─── Test: Specialist failures logged, not silently ignored ───────────────

setup_test "specialist sweep: failed specialists logged with names"
trap teardown_test EXIT

init_test_workspace

# Create a SPEC.md with specialists
push_file_to_repo "SPEC.md" "# Spec
## Specialists
### GoodSpecialist
You always succeed.
### BadSpecialist
You always fail.
### OtherGood
You also succeed." "add specialists"

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true; }

# Mock docker_run_specialist: BadSpecialist fails, others succeed
docker_run_specialist() {
    local name="$1"
    if [[ "$name" == "BadSpecialist" ]]; then
        return 1
    fi
    return 0
}

# Capture log output
LOG_OUTPUT=""
log()  { LOG_OUTPUT+="$*"$'\n'; }
warn() { LOG_OUTPUT+="WARN: $*"$'\n'; }

_g_specialist_count=0
run_specialist_sweep "test-failure"

echo "$LOG_OUTPUT" | grep -q "BadSpecialist failed" \
    && pass "failed specialist name logged" \
    || fail "failed specialist name not in log output"

echo "$LOG_OUTPUT" | grep -q "1 of 3 specialist(s) failed" \
    && pass "failure count logged correctly" \
    || fail "failure count not logged (log: $LOG_OUTPUT)"

teardown_test
trap - EXIT

print_summary
