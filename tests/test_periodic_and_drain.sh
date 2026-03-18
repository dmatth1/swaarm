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

# ─── Test 9: TESTS_FAIL → orchestrator fix task → TESTS_PASS completes run ───

setup_test "artifact compliance: TESTS_FAIL → orchestrator fix task → TESTS_PASS"
trap teardown_test EXIT

init_test_workspace

# Pre-populate: 1 done task (worker completed it, but required artifact is missing)
push_file_to_repo "tasks/done/001-build-app.md" "# Task 001: Build App
## Acceptance Criteria
- Run: python -m pytest
- Run: cat test-results.txt
  Expected: PASS" "done 001"

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true; }
run_specialist_sweep()           { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=999

ORCHESTRATOR_NEXT_NUMS=()
docker_run_orchestrator() {
    ORCHESTRATOR_NEXT_NUMS+=("${1:-}")
    # Simulate: orchestrator sees missing artifact, creates fix task directly in done/
    # (represents the full cycle: orchestrator creates fix task → worker completes it)
    push_file_to_repo "tasks/done/$(printf '%03d' "$1")-fix-missing-artifact.md" \
        "# Task $1: Generate missing test-results.txt" "orchestrator+worker: fix artifact"
    mkdir -p "$LOGS_DIR"
}

REVIEWER_CALL_NUM=0
docker_run_reviewer() {
    REVIEWER_CALL_NUM=$((REVIEWER_CALL_NUM + 1))
    mkdir -p "$LOGS_DIR"
    if [[ "$REVIEWER_CALL_NUM" -eq 1 ]]; then
        # Per-task review of 001: TESTS_FAIL (missing artifact)
        echo "TESTS_FAIL" > "$LOGS_DIR/reviewer-$2.log"
    else
        # After orchestrator added fix task: tests pass
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# Orchestrator triggered with correct NEXT_TASK_NUM
[[ "${#ORCHESTRATOR_NEXT_NUMS[@]}" -ge 1 ]] \
    && pass "orchestrator triggered after TESTS_FAIL (${#ORCHESTRATOR_NEXT_NUMS[@]} calls)" \
    || fail "orchestrator not triggered after TESTS_FAIL"

[[ "${ORCHESTRATOR_NEXT_NUMS[0]:-}" == "2" ]] \
    && pass "orchestrator received correct NEXT_TASK_NUM=2 (after done task 001)" \
    || fail "expected NEXT_TASK_NUM=2, got: ${ORCHESTRATOR_NEXT_NUMS[0]:-unset}"

# Fix task should exist in done/
[[ -f "$MAIN_DIR/tasks/done/002-fix-missing-artifact.md" ]] \
    && pass "fix task 002 created by orchestrator and resolved" \
    || fail "fix task 002 not found in done/"

teardown_test
trap - EXIT

# ─── Test 10: Resume with 0 pending triggers final drain (specialist sweep + reviewer) ──

setup_test "resume final drain: 0 pending/0 active triggers final specialist sweep + test reviewer"
trap teardown_test EXIT

init_test_workspace

# Pre-populate: 5 done tasks, 0 pending, 0 active
for i in 1 2 3 4 5; do
    push_file_to_repo "tasks/done/$(printf '%03d' $i)-task.md" "# Task $i" "done $i"
done

# Pre-populate reviewed.list so tasks are not re-reviewed
mkdir -p "$OUTPUT_DIR"
for i in 1 2 3 4 5; do
    echo "$(printf '%03d' $i)-task.md"
done > "$OUTPUT_DIR/reviewed.list"

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=999

SPECIALIST_SWEEPS=()
run_specialist_sweep() { SPECIALIST_SWEEPS+=("$1"); }

docker_run_orchestrator() { mkdir -p "$LOGS_DIR"; }

FINAL_REVIEWER_RAN=false
docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    if [[ "$1" == "--final--" ]]; then
        FINAL_REVIEWER_RAN=true
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

run_with_review 1

# Check final specialist sweep ran
found_final_sweep=false
for sweep in "${SPECIALIST_SWEEPS[@]+"${SPECIALIST_SWEEPS[@]}"}"; do
    [[ "$sweep" == "final" ]] && found_final_sweep=true
done
[[ "$found_final_sweep" == "true" ]] \
    && pass "final specialist sweep triggered" \
    || fail "final specialist sweep did not run (sweeps: ${SPECIALIST_SWEEPS[*]+"${SPECIALIST_SWEEPS[*]}"})"

# Check final test reviewer ran
[[ "$FINAL_REVIEWER_RAN" == "true" ]] \
    && pass "final test reviewer ran" \
    || fail "final test reviewer did not run"

teardown_test
trap - EXIT

# ─── Test 11: Periodic orchestrator does NOT fire immediately on resume ──────

setup_test "resume final drain: periodic orchestrator does NOT fire with done=reviewed (no new completions)"
trap teardown_test EXIT

init_test_workspace

# Pre-populate: 10 done tasks (well past any interval)
for i in $(seq 1 10); do
    push_file_to_repo "tasks/done/$(printf '%03d' $i)-task.md" "# Task $i" "done $i"
done

# Pre-populate reviewed.list with all 10
mkdir -p "$OUTPUT_DIR"
for i in $(seq 1 10); do
    echo "$(printf '%03d' $i)-task.md"
done > "$OUTPUT_DIR/reviewed.list"

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=3

ORCHESTRATOR_CALLS=0
docker_run_orchestrator() {
    ORCHESTRATOR_CALLS=$((ORCHESTRATOR_CALLS + 1))
    mkdir -p "$LOGS_DIR"
}

run_specialist_sweep() { :; }

docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

[[ "$ORCHESTRATOR_CALLS" -eq 0 ]] \
    && pass "periodic orchestrator did NOT fire on resume (no new completions)" \
    || fail "periodic orchestrator fired $ORCHESTRATOR_CALLS time(s) — should be 0 on resume with no new work"

teardown_test
trap - EXIT

# ─── Test 12: reviewed.list persists across restarts ─────────────────────────

setup_test "resume final drain: reviewed.list persists — tasks reviewed in run 1 skipped in run 2"
trap teardown_test EXIT

init_test_workspace

# Pre-populate: 3 done tasks
for i in 1 2 3; do
    push_file_to_repo "tasks/done/$(printf '%03d' $i)-task.md" "# Task $i" "done $i"
done

load_swarm

docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }
MAX_WORKER_ITERATIONS=5
RESTRUCTURE_INTERVAL=999

run_specialist_sweep() { :; }
docker_run_orchestrator() { mkdir -p "$LOGS_DIR"; }

REVIEW_COUNT_RUN1=0
docker_run_reviewer() {
    REVIEW_COUNT_RUN1=$((REVIEW_COUNT_RUN1 + 1))
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

# Run 1: reviews all 3 tasks + final reviewer
run_with_review 1

# Verify reviewed.list was written
[[ -f "$OUTPUT_DIR/reviewed.list" ]] \
    && pass "reviewed.list created after run 1" \
    || fail "reviewed.list not found after run 1"

reviewed_count=$(wc -l < "$OUTPUT_DIR/reviewed.list" | tr -d ' ')
[[ "$reviewed_count" -eq 3 ]] \
    && pass "reviewed.list has 3 entries" \
    || fail "expected 3 entries in reviewed.list, got $reviewed_count"

# Run 2: same done tasks, should skip all reviews
REVIEW_COUNT_RUN2=0
docker_run_reviewer() {
    REVIEW_COUNT_RUN2=$((REVIEW_COUNT_RUN2 + 1))
    mkdir -p "$LOGS_DIR"
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

run_with_review 1

# Run 2 should only have the final reviewer (1 call), no per-task reviews
[[ "$REVIEW_COUNT_RUN2" -le 1 ]] \
    && pass "run 2 skipped per-task reviews ($REVIEW_COUNT_RUN2 reviewer calls, expected 0-1 for final only)" \
    || fail "run 2 re-reviewed tasks ($REVIEW_COUNT_RUN2 calls, expected 0-1)"

# Run 1 should have had more reviews (3 per-task + 1 final = 4)
[[ "$REVIEW_COUNT_RUN1" -ge 3 ]] \
    && pass "run 1 reviewed all tasks ($REVIEW_COUNT_RUN1 calls)" \
    || fail "run 1 should have reviewed 3+ tasks, got $REVIEW_COUNT_RUN1"

teardown_test
trap - EXIT

print_summary
