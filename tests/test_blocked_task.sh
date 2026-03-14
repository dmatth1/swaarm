#!/usr/bin/env bash
# Integration tests for BLOCKED task escalation.
# No Docker or Claude needed — tests the scan logic directly.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# Helper: run one pass of the BLOCKED scan (extracted from run_with_review)
run_blocked_scan() {
    local task_file task_name
    for task_file in "$MAIN_DIR/tasks/pending/BLOCKED-"*.md; do
        [[ -f "$task_file" ]] || continue
        task_name=$(basename "$task_file")
        review_count=$((review_count + 1))
        docker_run_reviewer "$task_name" "$review_count"
    done
}

# ─── Test 1: BLOCKED file triggers reviewer with its filename ─────────────────

setup_test "blocked task: reviewer called with BLOCKED filename as COMPLETED_TASK"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo \
    "tasks/pending/BLOCKED-003-hard-task.md" \
    "# Task 003\n## Blocker\nUnable to resolve missing module." \
    "worker-1: block 003"

load_swarm

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    # Write a REVIEW_DONE signal so any callers that check logs don't hang
    mkdir -p "$LOGS_DIR"
    echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
}

review_count=0
run_blocked_scan

assert_eq "1"                     "${#REVIEWER_CALLS[@]}"  "reviewer called once"
assert_eq "BLOCKED-003-hard-task.md" "${REVIEWER_CALLS[0]}"  "reviewer received BLOCKED filename"

teardown_test
trap - EXIT

# ─── Test 2: normal pending file is NOT escalated ─────────────────────────────

setup_test "blocked task: normal pending file not escalated to reviewer"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo \
    "tasks/pending/002-normal-task.md" \
    "# Task 002\n## Acceptance Criteria\n- [ ] Run: echo hi → Expected: hi" \
    "add normal task"

load_swarm

REVIEWER_CALLS=()
docker_run_reviewer() { REVIEWER_CALLS+=("$1"); }

review_count=0
run_blocked_scan

assert_eq "0" "${#REVIEWER_CALLS[@]}" "normal task not escalated"

teardown_test
trap - EXIT

# ─── Test 3: multiple BLOCKED files each trigger a reviewer call ──────────────

setup_test "blocked task: each BLOCKED file gets its own reviewer call"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/BLOCKED-004-auth.md"   "# 004\n## Blocker\ncannot resolve" "block 004"
push_file_to_repo "tasks/pending/BLOCKED-007-deploy.md" "# 007\n## Blocker\nmissing creds"  "block 007"

load_swarm

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
}

review_count=0
run_blocked_scan

assert_eq "2" "${#REVIEWER_CALLS[@]}" "reviewer called once per blocked task"

teardown_test
trap - EXIT

# ─── Test 4: already-reviewed BLOCKED file is not re-escalated ───────────────

setup_test "blocked task: BLOCKED file not escalated twice in same session"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo \
    "tasks/pending/BLOCKED-005-parse.md" \
    "# 005\n## Blocker\nparser ambiguity" \
    "block 005"

load_swarm

REVIEWER_CALLS=()
docker_run_reviewer() {
    REVIEWER_CALLS+=("$1")
    mkdir -p "$LOGS_DIR"
    echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-$2.log"
}

# First pass
review_count=0
blocked_reviewed=()
run_blocked_scan
blocked_reviewed+=("BLOCKED-005-parse.md")

# Second pass — same file, should be skipped
for task_file in "$MAIN_DIR/tasks/pending/BLOCKED-"*.md; do
    [[ -f "$task_file" ]] || continue
    task_name=$(basename "$task_file")
    local_already_reviewed=false
    for br in "${blocked_reviewed[@]+"${blocked_reviewed[@]}"}"; do
        [[ "$br" == "$task_name" ]] && local_already_reviewed=true && break
    done
    [[ "$local_already_reviewed" == "true" ]] && continue
    review_count=$((review_count + 1))
    docker_run_reviewer "$task_name" "$review_count"
done

assert_eq "1" "${#REVIEWER_CALLS[@]}" "BLOCKED file only escalated once"

teardown_test
trap - EXIT

print_summary
