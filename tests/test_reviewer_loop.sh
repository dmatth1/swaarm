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
