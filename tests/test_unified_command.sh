#!/usr/bin/env bash
# Integration tests for the unified ./swarm command (new run vs resume detection).
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Set up mocks for main() — prevent real Docker/orchestrator/worker calls
setup_main_mocks() {
    ensure_docker_image()        { :; }
    cleanup_docker()             { :; }
    docker_run_orchestrator()    {
        ORCHESTRATOR_CALLED=true
        ORCHESTRATOR_NEXT_NUM="${1:-}"
        # Create a dummy done task so main() doesn't exit with "no tasks completed"
        mkdir -p "$MAIN_DIR/tasks/done"
        echo "# dummy" > "$MAIN_DIR/tasks/done/001-setup.md"
        return 0
    }
    docker_run_worker()          { :; }
    docker_run_reviewer()        {
        mkdir -p "$LOGS_DIR"
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-$2.log"
    }
    run_with_review()            {
        RWR_CALLED=true; RWR_AGENTS="$1"
        # Create a done task so main() doesn't exit with "no tasks completed"
        mkdir -p "$MAIN_DIR/tasks/done"
        echo "# dummy" > "$MAIN_DIR/tasks/done/999-dummy.md"
    }
    run_specialist_sweep()       { :; }
    monitor_progress()           { :; }
    check_and_respawn_dead_workers() { :; }
    sleep()                      { :; }
    sync_main()                  { :; }
    sync_remote()                { :; }
    init_workspace() {
        mkdir -p "$REPO_DIR" "$LOGS_DIR" "$MAIN_DIR/tasks/pending" "$MAIN_DIR/tasks/active" "$MAIN_DIR/tasks/done"
        git init --bare "$REPO_DIR" -q
        INIT_WORKSPACE_CALLED=true
    }

    ORCHESTRATOR_CALLED=false
    ORCHESTRATOR_NEXT_NUM=""
    RWR_CALLED=false
    RWR_AGENTS=""
    INIT_WORKSPACE_CALLED=false
}

# ─── Test 1: New run — output dir doesn't exist ──────────────────────────────

setup_test "unified: new run when output dir doesn't exist"
trap teardown_test EXIT

load_swarm
setup_main_mocks

TASK="Build a REST API"
NUM_AGENTS=3
OUTPUT_DIR="$TEST_TMPDIR/swarm-new"
REPO_DIR="$OUTPUT_DIR/repo.git"
LOGS_DIR="$OUTPUT_DIR/logs"
MAIN_DIR="$OUTPUT_DIR/main"

main 2>/dev/null || true

[[ "$INIT_WORKSPACE_CALLED" == "true" ]] \
    && pass "init_workspace called for new run" \
    || fail "init_workspace not called"

[[ "$ORCHESTRATOR_CALLED" == "true" ]] \
    && pass "orchestrator called for new run" \
    || fail "orchestrator not called"

[[ "$RWR_CALLED" == "true" ]] \
    && pass "run_with_review called" \
    || fail "run_with_review not called"

[[ -z "$ORCHESTRATOR_NEXT_NUM" ]] \
    && pass "orchestrator called in new-project mode (no NEXT_NUM)" \
    || fail "orchestrator should not have NEXT_NUM for new run"

teardown_test
trap - EXIT

# ─── Test 2: Resume — existing dir, same prompt ──────────────────────────────

setup_test "unified: resume when output dir exists (same prompt)"
trap teardown_test EXIT

init_test_workspace
load_swarm
setup_main_mocks

# Simulate existing run with state file
{
    printf 'SWARM_TASK=%q\n' "Build a REST API"
    printf 'SWARM_AGENTS=%s\n' "3"
    printf 'SWARM_MODEL=%q\n' ""
    printf 'SWARM_REPO=%q\n' ""
} > "$OUTPUT_DIR/swarm.state"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

TASK="Build a REST API"
NUM_AGENTS=2

main 2>/dev/null || true

[[ "$INIT_WORKSPACE_CALLED" == "false" ]] \
    && pass "init_workspace NOT called for resume" \
    || fail "init_workspace should not be called for resume"

[[ "$ORCHESTRATOR_CALLED" == "false" ]] \
    && pass "orchestrator NOT called for resume" \
    || fail "orchestrator should not be called for resume"

[[ "$ORCHESTRATOR_CALLED" == "false" ]] \
    && pass "orchestrator NOT called when prompt matches original" \
    || fail "orchestrator should not be called when prompt matches"

[[ "$RWR_CALLED" == "true" ]] \
    && pass "run_with_review called for resume" \
    || fail "run_with_review not called for resume"

teardown_test
trap - EXIT

# ─── Test 3: Resume — existing dir, different prompt → orchestrator augment ───

setup_test "unified: resume with new guidance triggers orchestrator augment"
trap teardown_test EXIT

init_test_workspace
load_swarm
setup_main_mocks

{
    printf 'SWARM_TASK=%q\n' "Build a REST API"
    printf 'SWARM_AGENTS=%s\n' "3"
    printf 'SWARM_MODEL=%q\n' ""
    printf 'SWARM_REPO=%q\n' ""
} > "$OUTPUT_DIR/swarm.state"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
push_file_to_repo "tasks/done/002-build.md" "# Task 002" "done task"

TASK="Also add rate limiting"
NUM_AGENTS=3

main 2>/dev/null || true

[[ "$ORCHESTRATOR_CALLED" == "true" ]] \
    && pass "orchestrator called when prompt differs from original" \
    || fail "orchestrator should be called when prompt changes"

# next_num should be 3 (max is 002 → next is 3)
assert_eq "3" "$ORCHESTRATOR_NEXT_NUM" "orchestrator augment starts at task 003"

[[ "$RWR_CALLED" == "true" ]] \
    && pass "run_with_review called after augment" \
    || fail "run_with_review not called after augment"

teardown_test
trap - EXIT

# ─── Test 4: Resume — stuck tasks returned to pending ─────────────────────────

setup_test "unified: resume unsticks active tasks"
trap teardown_test EXIT

init_test_workspace
load_swarm
setup_main_mocks

{
    printf 'SWARM_TASK=%q\n' "Build a thing"
    printf 'SWARM_AGENTS=%s\n' "1"
    printf 'SWARM_MODEL=%q\n' ""
    printf 'SWARM_REPO=%q\n' ""
} > "$OUTPUT_DIR/swarm.state"

push_file_to_repo "tasks/active/worker-1--001-setup.md" "# Task 001" "stuck task"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002" "pending task"

TASK="Build a thing"
NUM_AGENTS=1

# Need real sync_main for unstick verification
sync_main() { (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true; }

main 2>/dev/null || true

# Check the stuck task was returned to pending
[[ -f "$MAIN_DIR/tasks/pending/001-setup.md" ]] \
    && pass "stuck task returned to pending" \
    || fail "stuck task not returned to pending"

[[ ! -f "$MAIN_DIR/tasks/active/worker-1--001-setup.md" ]] \
    && pass "stuck task removed from active" \
    || fail "stuck task still in active"

teardown_test
trap - EXIT

# ─── Test 5: Resume — state file model/repo restored, CLI overrides ──────────

setup_test "unified: resume restores model/repo from state, CLI overrides"
trap teardown_test EXIT

init_test_workspace
load_swarm
setup_main_mocks

{
    printf 'SWARM_TASK=%q\n' "Build a thing"
    printf 'SWARM_AGENTS=%s\n' "2"
    printf 'SWARM_MODEL=%q\n' "sonnet"
    printf 'SWARM_REPO=%q\n' "https://github.com/user/repo"
} > "$OUTPUT_DIR/swarm.state"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

TASK="Build a thing"
NUM_AGENTS=2
MODEL=""  # not set on CLI → should restore from state
REMOTE_REPO=""  # not set on CLI → should restore from state

main 2>/dev/null || true

assert_eq "sonnet" "$MODEL" "MODEL restored from state file"
assert_eq "https://github.com/user/repo" "$REMOTE_REPO" "REMOTE_REPO restored from state file"

teardown_test
trap - EXIT

# ─── Test 6: Resume — CLI model overrides state file ─────────────────────────

setup_test "unified: CLI --model overrides state file model"
trap teardown_test EXIT

init_test_workspace
load_swarm
setup_main_mocks

{
    printf 'SWARM_TASK=%q\n' "Build a thing"
    printf 'SWARM_AGENTS=%s\n' "1"
    printf 'SWARM_MODEL=%q\n' "sonnet"
    printf 'SWARM_REPO=%q\n' ""
} > "$OUTPUT_DIR/swarm.state"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

TASK="Build a thing"
NUM_AGENTS=1
MODEL="opus"  # CLI override

main 2>/dev/null || true

assert_eq "opus" "$MODEL" "CLI --model opus overrides state sonnet"

teardown_test
trap - EXIT

# ─── Test 7: All tasks complete → early exit ──────────────────────────────────

setup_test "unified: resume exits early when all tasks done"
trap teardown_test EXIT

init_test_workspace
load_swarm
setup_main_mocks

{
    printf 'SWARM_TASK=%q\n' "Build a thing"
    printf 'SWARM_AGENTS=%s\n' "1"
    printf 'SWARM_MODEL=%q\n' ""
    printf 'SWARM_REPO=%q\n' ""
} > "$OUTPUT_DIR/swarm.state"

# No pending tasks — all done
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

TASK="Build a thing"
NUM_AGENTS=1

main 2>/dev/null || true

[[ "$RWR_CALLED" == "false" ]] \
    && pass "run_with_review NOT called when all tasks done" \
    || fail "run_with_review should not be called when nothing to do"

teardown_test
trap - EXIT

print_summary
