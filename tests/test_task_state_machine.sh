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
