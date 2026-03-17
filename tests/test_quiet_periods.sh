#!/usr/bin/env bash
# Tests for periodic orchestrator + specialist sweep (every N completions, concurrent with workers).
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ─── Test 1: Periodic orchestrator + specialist sweep triggers after N completions

setup_test "periodic restructure: orchestrator + sweep trigger after N completions (interval=3)"
trap teardown_test EXIT

init_test_workspace

# Pre-populate 3 done tasks (enough to trigger at interval=3)
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done 001"
push_file_to_repo "tasks/done/002-build.md" "# Task 002" "done 002"
push_file_to_repo "tasks/done/003-routes.md" "# Task 003" "done 003"

load_swarm

# Mock everything
docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=3

SPECIALIST_SWEEPS=()
ORCHESTRATOR_CALLS=()

run_specialist_sweep()  { SPECIALIST_SWEEPS+=("$1"); }

docker_run_orchestrator() {
    ORCHESTRATOR_CALLS+=("periodic")
    mkdir -p "$LOGS_DIR"
}

docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# Check that a periodic orchestrator ran
[[ "${#ORCHESTRATOR_CALLS[@]}" -ge 1 ]] \
    && pass "periodic orchestrator ran at completion threshold" \
    || fail "no periodic orchestrator call (calls: ${#ORCHESTRATOR_CALLS[@]})"

# Check specialist sweep ran
found_sweep=false
for sweep in "${SPECIALIST_SWEEPS[@]+"${SPECIALIST_SWEEPS[@]}"}"; do
    if [[ "$sweep" == *"at "* ]]; then
        found_sweep=true
        break
    fi
done
[[ "$found_sweep" == "true" ]] \
    && pass "specialist sweep ran at completion threshold" \
    || fail "no specialist sweep (sweeps: ${SPECIALIST_SWEEPS[*]:-none})"

teardown_test
trap - EXIT

# ─── Test 2: Per-task reviewer called without mode arg ───────────────────────

setup_test "periodic restructure: per-task reviewer called without REVIEW_MODE"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }
run_specialist_sweep()           { :; }
docker_run_orchestrator()        { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=999  # no periodic orchestrator

REVIEWER_ARG_COUNTS=()
docker_run_reviewer() {
    REVIEWER_ARG_COUNTS+=("$#")
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# Per-task reviewer should be called with 2 args (task_name, review_num) — no mode arg
[[ "${REVIEWER_ARG_COUNTS[0]}" -eq 2 ]] \
    && pass "per-task reviewer called with 2 args (no REVIEW_MODE)" \
    || fail "expected 2 args, got: ${REVIEWER_ARG_COUNTS[0]:-unset}"

teardown_test
trap - EXIT

# ─── Test 3: No periodic orchestrator below threshold ─────────────────────────

setup_test "periodic restructure: does not trigger below threshold"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"
push_file_to_repo "tasks/done/002-build.md" "# Task 002" "done"

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }
run_specialist_sweep()           { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=5  # threshold is 5, only 2 done

PERIODIC_ORCHESTRATOR_CALLS=0
docker_run_orchestrator() {
    # Only count calls with a next_task_num arg (periodic/stuck/blocked — not test-fail-triggered)
    PERIODIC_ORCHESTRATOR_CALLS=$((PERIODIC_ORCHESTRATOR_CALLS + 1))
    mkdir -p "$LOGS_DIR"
}

docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# Orchestrator should not have been called for periodic restructuring (only final drain path)
# The final drain doesn't call orchestrator (it calls reviewer which says TESTS_PASS)
[[ "$PERIODIC_ORCHESTRATOR_CALLS" -eq 0 ]] \
    && pass "no periodic orchestrator triggered (2 done < threshold 5)" \
    || fail "orchestrator triggered too early ($PERIODIC_ORCHESTRATOR_CALLS calls)"

teardown_test
trap - EXIT

# ─── Test 4: RESTRUCTURE_INTERVAL is configurable ────────────────────────────

setup_test "periodic restructure: RESTRUCTURE_INTERVAL is configurable"
trap teardown_test EXIT

init_test_workspace
# 5 done tasks + threshold of 5 = exactly hits periodic orchestrator
for i in $(seq 1 5); do
    push_file_to_repo "tasks/done/$(printf '%03d' $i)-task.md" "# Task $i" "done $i"
done

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }
run_specialist_sweep()           { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=5

PERIODIC_CALLS=0
LAST_PERIODIC_ARG=""
docker_run_orchestrator() {
    PERIODIC_CALLS=$((PERIODIC_CALLS + 1))
    LAST_PERIODIC_ARG="${1:-}"
    mkdir -p "$LOGS_DIR"
}

docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

[[ "$PERIODIC_CALLS" -ge 1 ]] \
    && pass "periodic orchestrator triggered at custom interval (5)" \
    || fail "periodic orchestrator not triggered at interval=5 with 5 done tasks"

teardown_test
trap - EXIT

# ─── Test 5: TESTS_FAIL triggers orchestrator immediately ─────────────────────

setup_test "periodic restructure: TESTS_FAIL from reviewer triggers orchestrator immediately"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }
run_specialist_sweep()           { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=999

ORCHESTRATOR_CALL_COUNT=0
docker_run_orchestrator() {
    ORCHESTRATOR_CALL_COUNT=$((ORCHESTRATOR_CALL_COUNT + 1))
    mkdir -p "$LOGS_DIR"
}

REVIEWER_CALL_NUM=0
docker_run_reviewer() {
    REVIEWER_CALL_NUM=$((REVIEWER_CALL_NUM + 1))
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    elif [[ "$REVIEWER_CALL_NUM" -eq 1 ]]; then
        # First per-task review: fail tests
        echo "TESTS_FAIL" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

[[ "$ORCHESTRATOR_CALL_COUNT" -ge 1 ]] \
    && pass "orchestrator triggered after TESTS_FAIL" \
    || fail "orchestrator not triggered after TESTS_FAIL"

teardown_test
trap - EXIT

# ─── Test 6: Reviewer prompt has no REVIEW_MODE ───────────────────────────────

setup_test "periodic restructure: reviewer prompt has no REVIEW_MODE placeholder"
trap teardown_test EXIT

REVIEWER_PROMPT="$TESTS_DIR/../prompts/reviewer.md"

grep -q 'REVIEW_MODE' "$REVIEWER_PROMPT" \
    && fail "reviewer prompt still references REVIEW_MODE (should be removed)" \
    || pass "reviewer prompt has no REVIEW_MODE placeholder"

grep -q 'TESTS_PASS\|TESTS_FAIL' "$REVIEWER_PROMPT" \
    && pass "reviewer prompt uses TESTS_PASS/TESTS_FAIL signals" \
    || fail "reviewer prompt missing TESTS_PASS/TESTS_FAIL signals"

teardown_test
trap - EXIT

# ─── Test 7: Entrypoint has no REVIEW_MODE ────────────────────────────────────

setup_test "periodic restructure: entrypoint does not pass REVIEW_MODE"
trap teardown_test EXIT

ENTRYPOINT="$TESTS_DIR/../docker/entrypoint.sh"

grep -q 'REVIEW_MODE' "$ENTRYPOINT" \
    && fail "entrypoint still references REVIEW_MODE (should be removed)" \
    || pass "entrypoint has no REVIEW_MODE"

teardown_test
trap - EXIT

# ─── Test 8: docker_run_reviewer takes 2 args (no mode) ──────────────────────

setup_test "periodic restructure: docker_run_reviewer takes 2 args (not 3)"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Capture docker args
DOCKER_ARGS=""
docker() {
    DOCKER_ARGS="$*"
    return 0
}
get_claude_oauth_token() { echo "test-token"; }

docker_run_reviewer "001-setup.md" "1" 2>/dev/null || true

echo "$DOCKER_ARGS" | grep -q 'REVIEW_MODE' \
    && fail "docker_run_reviewer still passes REVIEW_MODE" \
    || pass "docker_run_reviewer does not pass REVIEW_MODE"

# Verify COMPLETED_TASK is still passed
echo "$DOCKER_ARGS" | grep -q 'COMPLETED_TASK=001-setup.md' \
    && pass "docker_run_reviewer still passes COMPLETED_TASK" \
    || fail "COMPLETED_TASK not in docker args: $DOCKER_ARGS"

teardown_test
trap - EXIT

print_summary
