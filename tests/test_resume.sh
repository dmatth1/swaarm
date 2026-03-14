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
