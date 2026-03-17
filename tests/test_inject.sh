#!/usr/bin/env bash
# Integration tests for cmd_inject.
# Mocks docker_run_inject to write task files directly.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ─── Test 1: inject creates new task files with correct numbering ─────────────

setup_test "inject: creates task files starting after existing max"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md"   "# Task 001" "done 001"
push_file_to_repo "tasks/done/002-build.md"   "# Task 002" "done 002"
push_file_to_repo "tasks/pending/003-tests.md" "# Task 003" "add 003"

load_swarm

CAPTURED_NEXT_NUM=""
CAPTURED_GUIDANCE=""
ensure_docker_image() { :; }
docker_run_inject() {
    local guidance="$1"
    local next_num="$2"
    CAPTURED_GUIDANCE="$guidance"
    CAPTURED_NEXT_NUM="$next_num"
    # Simulate agent creating a task file at the correct number
    local tmp
    tmp=$(mktemp -d)
    git clone "$REPO_DIR" "$tmp" -q 2>/dev/null
    (
        cd "$tmp"
        git config user.email "test@swarm"
        git config user.name "Test"
        printf '# Task %03d: Add auth\n' "$next_num" > "tasks/pending/$(printf '%03d' "$next_num")-add-auth.md"
        git add -A
        git commit -m "inject: add auth task" -q
        git push origin main -q
    )
    rm -rf "$tmp"
}

cmd_inject "$OUTPUT_DIR" "Add OAuth authentication"

assert_eq "4" "$CAPTURED_NEXT_NUM" "next_num passed as 4 (after max 003)"
assert_eq "Add OAuth authentication" "$CAPTURED_GUIDANCE" "guidance passed through"

(cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true
assert_file_exists "$MAIN_DIR/tasks/pending/004-add-auth.md" "task 004 created in pending"

teardown_test
trap - EXIT

# ─── Test 2: next_num starts at 1 when no tasks exist ────────────────────────

setup_test "inject: starts numbering at 1 when no tasks exist"
trap teardown_test EXIT

init_test_workspace
load_swarm

CAPTURED_NEXT_NUM=""
docker_run_inject() {
    CAPTURED_NEXT_NUM="$2"
}
ensure_docker_image() { :; }

cmd_inject "$OUTPUT_DIR" "Add login page"

assert_eq "1" "$CAPTURED_NEXT_NUM" "next_num is 1 when no tasks exist"

teardown_test
trap - EXIT

# ─── Test 3: missing output_dir → error ──────────────────────────────────────

setup_test "inject: missing output_dir exits with error"
trap teardown_test EXIT

init_test_workspace
load_swarm

output=$(cmd_inject "" "some guidance" 2>&1) && status=0 || status=$?

[[ "$status" -ne 0 ]] \
    && pass "exits non-zero on missing output_dir" \
    || fail "should have exited non-zero"

echo "$output" | grep -q "Usage:" \
    && pass "prints Usage on missing output_dir" \
    || fail "no Usage message"

teardown_test
trap - EXIT

# ─── Test 4: missing guidance → error ────────────────────────────────────────

setup_test "inject: missing guidance exits with error"
trap teardown_test EXIT

init_test_workspace
load_swarm

output=$(cmd_inject "$OUTPUT_DIR" "" 2>&1) && status=0 || status=$?

[[ "$status" -ne 0 ]] \
    && pass "exits non-zero on missing guidance" \
    || fail "should have exited non-zero"

echo "$output" | grep -q "guidance" \
    && pass "error message mentions guidance" \
    || fail "error message missing guidance"

teardown_test
trap - EXIT

# ─── Test 5: octal-safe numbering with zero-padded task numbers ──────────────

setup_test "inject: handles zero-padded task numbers 008/009 (octal-safe)"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/007-feature-a.md" "# Task 007" "done 007"
push_file_to_repo "tasks/done/008-feature-b.md" "# Task 008" "done 008"
push_file_to_repo "tasks/done/009-feature-c.md" "# Task 009" "done 009"
push_file_to_repo "tasks/pending/018-feature-d.md" "# Task 018" "add 018"
push_file_to_repo "tasks/pending/019-feature-e.md" "# Task 019" "add 019"

load_swarm

CAPTURED_NEXT_NUM=""
ensure_docker_image() { :; }
docker_run_inject() {
    CAPTURED_NEXT_NUM="$2"
}

cmd_inject "$OUTPUT_DIR" "Add more features"

assert_eq "20" "$CAPTURED_NEXT_NUM" "next_num is 20 (after max 019, octal-safe)"

teardown_test
trap - EXIT

print_summary
