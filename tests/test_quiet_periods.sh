#!/usr/bin/env bash
# Tests for quiet period feature: pause workers, drain, full review + specialists.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ─── Test 1: Quiet period triggers after N completions ─────────────────────────

setup_test "quiet period: triggers after N completions (interval=3)"
trap teardown_test EXIT

init_test_workspace

# Pre-populate 3 done tasks (enough to trigger quiet period at interval=3)
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
QUIET_PERIOD_INTERVAL=3

PAUSE_CALLS=0
UNPAUSE_CALLS=0
DRAIN_CALLS=0
SPECIALIST_SWEEPS=()
REVIEWER_CALLS=()

pause_workers()         { PAUSE_CALLS=$((PAUSE_CALLS + 1)); }
unpause_workers()       { UNPAUSE_CALLS=$((UNPAUSE_CALLS + 1)); }
wait_for_active_drain() { DRAIN_CALLS=$((DRAIN_CALLS + 1)); }
run_specialist_sweep()  { SPECIALIST_SWEEPS+=("$1"); }

docker_run_reviewer() {
    REVIEWER_CALLS+=("$1:${3:-full}")
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

[[ "$PAUSE_CALLS" -ge 1 ]] \
    && pass "pause_workers called ($PAUSE_CALLS time(s))" \
    || fail "pause_workers not called"

[[ "$UNPAUSE_CALLS" -ge 1 ]] \
    && pass "unpause_workers called ($UNPAUSE_CALLS time(s))" \
    || fail "unpause_workers not called"

[[ "$DRAIN_CALLS" -ge 1 ]] \
    && pass "wait_for_active_drain called ($DRAIN_CALLS time(s))" \
    || fail "wait_for_active_drain not called"

# Check that a full review ran during quiet period
found_full_review=false
for call in "${REVIEWER_CALLS[@]}"; do
    if [[ "$call" == "--full-review--:full" ]]; then
        found_full_review=true
        break
    fi
done
[[ "$found_full_review" == "true" ]] \
    && pass "--full-review-- ran with mode=full during quiet period" \
    || fail "no --full-review-- call found (calls: ${REVIEWER_CALLS[*]})"

# Check specialist sweep ran during quiet period
found_qp_sweep=false
for sweep in "${SPECIALIST_SWEEPS[@]+"${SPECIALIST_SWEEPS[@]}"}"; do
    if [[ "$sweep" == *"quiet-period"* ]]; then
        found_qp_sweep=true
        break
    fi
done
[[ "$found_qp_sweep" == "true" ]] \
    && pass "specialist sweep ran during quiet period" \
    || fail "no quiet-period specialist sweep (sweeps: ${SPECIALIST_SWEEPS[*]:-none})"

teardown_test
trap - EXIT

# ─── Test 2: Quick mode used for per-task reviews ─────────────────────────────

setup_test "quiet period: per-task reviews use quick mode"
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
pause_workers()                  { :; }
unpause_workers()                { :; }
wait_for_active_drain()          { :; }
run_specialist_sweep()           { :; }
MAX_WORKER_ITERATIONS=5
QUIET_PERIOD_INTERVAL=999  # no quiet period

REVIEWER_MODES=()
docker_run_reviewer() {
    REVIEWER_MODES+=("$1:${3:-unset}")
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# First call should be quick (per-task), final should be full (drain)
[[ "${REVIEWER_MODES[0]}" == "001-setup.md:quick" ]] \
    && pass "per-task review uses quick mode" \
    || fail "expected quick mode, got: ${REVIEWER_MODES[0]}"

teardown_test
trap - EXIT

# ─── Test 3: No quiet period before threshold ──────────────────────────────────

setup_test "quiet period: does not trigger below threshold"
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
QUIET_PERIOD_INTERVAL=5  # threshold is 5, only 2 done

PAUSE_CALLS=0
pause_workers()         { PAUSE_CALLS=$((PAUSE_CALLS + 1)); }
unpause_workers()       { :; }
wait_for_active_drain() { :; }

docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

[[ "$PAUSE_CALLS" -eq 0 ]] \
    && pass "no quiet period triggered (2 done < threshold 5)" \
    || fail "quiet period triggered too early ($PAUSE_CALLS pause calls)"

teardown_test
trap - EXIT

# ─── Test 4: Quiet period interval is configurable ─────────────────────────────

setup_test "quiet period: QUIET_PERIOD_INTERVAL is configurable"
trap teardown_test EXIT

init_test_workspace
# 5 done tasks + threshold of 5 = exactly hits quiet period
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
QUIET_PERIOD_INTERVAL=5

PAUSE_CALLS=0
pause_workers()         { PAUSE_CALLS=$((PAUSE_CALLS + 1)); }
unpause_workers()       { :; }
wait_for_active_drain() { :; }

docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

[[ "$PAUSE_CALLS" -ge 1 ]] \
    && pass "quiet period triggered at custom interval (5)" \
    || fail "quiet period not triggered at interval=5 with 5 done tasks"

teardown_test
trap - EXIT

# ─── Test 5: Full review mode used during quiet period ─────────────────────────

setup_test "quiet period: full review has restructuring powers"
trap teardown_test EXIT

init_test_workspace
for i in $(seq 1 10); do
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
pause_workers()                  { :; }
unpause_workers()                { :; }
wait_for_active_drain()          { :; }
MAX_WORKER_ITERATIONS=20
QUIET_PERIOD_INTERVAL=10

FULL_REVIEW_TASKS=()
docker_run_reviewer() {
    if [[ "${3:-}" == "full" && "$1" != "--final--" ]]; then
        FULL_REVIEW_TASKS+=("$1")
    fi
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

[[ "${#FULL_REVIEW_TASKS[@]}" -ge 1 ]] \
    && pass "full review ran during quiet period" \
    || fail "no full review during quiet period"

if [[ "${#FULL_REVIEW_TASKS[@]}" -ge 1 ]]; then
    [[ "${FULL_REVIEW_TASKS[0]}" == "--full-review--" ]] \
        && pass "full review received --full-review-- as COMPLETED_TASK" \
        || fail "expected --full-review--, got: ${FULL_REVIEW_TASKS[0]}"
else
    fail "no full review task to check COMPLETED_TASK value"
fi

teardown_test
trap - EXIT

# ─── Test 6: REVIEW_MODE passed through entrypoint ────────────────────────────

setup_test "quiet period: REVIEW_MODE substituted in reviewer prompt"
trap teardown_test EXIT

ENTRYPOINT="$TESTS_DIR/../docker/entrypoint.sh"

# Verify the entrypoint substitutes REVIEW_MODE
grep -q 'REVIEW_MODE' "$ENTRYPOINT" \
    && pass "entrypoint reads REVIEW_MODE env var" \
    || fail "entrypoint missing REVIEW_MODE"

grep -q '{{REVIEW_MODE}}' "$TESTS_DIR/../prompts/reviewer.md" \
    && pass "reviewer prompt has {{REVIEW_MODE}} placeholder" \
    || fail "reviewer prompt missing {{REVIEW_MODE}} placeholder"

teardown_test
trap - EXIT

# ─── Test 7: Reviewer prompt has --full-review-- handling ──────────────────────

setup_test "quiet period: reviewer prompt handles --full-review--"
trap teardown_test EXIT

REVIEWER_PROMPT="$TESTS_DIR/../prompts/reviewer.md"

grep -q '\-\-full-review\-\-' "$REVIEWER_PROMPT" \
    && pass "reviewer prompt documents --full-review--" \
    || fail "reviewer prompt missing --full-review-- handling"

grep -q 'quick' "$REVIEWER_PROMPT" \
    && pass "reviewer prompt documents quick mode" \
    || fail "reviewer prompt missing quick mode docs"

teardown_test
trap - EXIT

# ─── Test 8: docker_run_reviewer passes REVIEW_MODE ───────────────────────────

setup_test "quiet period: docker_run_reviewer passes REVIEW_MODE env var"
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

docker_run_reviewer "001-setup.md" "1" "quick" 2>/dev/null || true

echo "$DOCKER_ARGS" | grep -q 'REVIEW_MODE=quick' \
    && pass "docker_run_reviewer passes REVIEW_MODE=quick" \
    || fail "REVIEW_MODE not in docker args: $DOCKER_ARGS"

DOCKER_ARGS=""
docker_run_reviewer "002-build.md" "2" "full" 2>/dev/null || true

echo "$DOCKER_ARGS" | grep -q 'REVIEW_MODE=full' \
    && pass "docker_run_reviewer passes REVIEW_MODE=full" \
    || fail "REVIEW_MODE not in docker args: $DOCKER_ARGS"

teardown_test
trap - EXIT

print_summary
