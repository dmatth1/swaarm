#!/usr/bin/env bash
# Integration tests for cmd_status.
# Uses real git workspace. No Docker needed — avoids .cid files,
# uses log files for worker status instead.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# Strip ANSI color codes from output for assertion-friendly text
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ─── Test 1: Correct task counts displayed ────────────────────────────────────

setup_test "status: correct pending / active / done counts"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md"              "# 001" "add"
push_file_to_repo "tasks/pending/002-build.md"              "# 002" "add"
push_file_to_repo "tasks/active/worker-1--003-deploy.md"    "# 003" "claim"
push_file_to_repo "tasks/done/004-init.md"                  "# 004" "done"

load_swarm

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "2 pending" "2 pending shown"
assert_output_contains "$output" "1 active"  "1 active shown"
assert_output_contains "$output" "1 done"    "1 done shown"

teardown_test
trap - EXIT

# ─── Test 2: Active task listed with worker assignment ────────────────────────

setup_test "status: active task shown with worker name"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/active/worker-2--005-migrate.md" "# 005" "w2: claim"

load_swarm

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "worker-2"        "worker-2 shown in active tasks"
assert_output_contains "$output" "005-migrate.md"  "task name shown"

teardown_test
trap - EXIT

# ─── Test 3: Done tasks listed ───────────────────────────────────────────────

setup_test "status: done tasks listed by filename"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md" "# 001" "done"
push_file_to_repo "tasks/done/002-build.md" "# 002" "done"

load_swarm

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "001-setup.md" "001-setup.md in done list"
assert_output_contains "$output" "002-build.md" "002-build.md in done list"

teardown_test
trap - EXIT

# ─── Test 4: Task description read from SPEC.md ──────────────────────────────

setup_test "status: task description from SPEC.md displayed"
trap teardown_test EXIT

init_test_workspace

# Update SPEC.md with a real task description
tmp=$(mktemp -d)
git clone "$REPO_DIR" "$tmp" -q 2>/dev/null
(
    cd "$tmp"
    git config user.email "test@swarm"
    git config user.name "Test"
    printf '# Project Specification\n\n**Task:** build a rocket ship\n' > SPEC.md
    git add SPEC.md
    git commit -m "update spec" -q
    git push origin main -q
)
rm -rf "$tmp"
(cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true

load_swarm

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "build a rocket ship" "task description from SPEC.md shown"

teardown_test
trap - EXIT

# ─── Test 5: Worker log "DONE at" shows DONE status ──────────────────────────

setup_test "status: worker with DONE log shows DONE status"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Create a worker log indicating completion (no .cid file — worker exited cleanly)
mkdir -p "$LOGS_DIR"
printf '=== Worker 1 started\n=== Worker 1 DONE at Thu Jan 1 00:00:00 UTC 2026 ===\n' \
    > "$LOGS_DIR/worker-1.log"

output=$(cmd_status "$OUTPUT_DIR" 2>&1 | strip_ansi)

assert_output_contains "$output" "DONE" "DONE status shown for completed worker"

teardown_test
trap - EXIT

print_summary
