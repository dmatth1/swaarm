#!/usr/bin/env bash
# Integration tests for cmd_kill.
# Tests kill-specific-worker, kill-all, and error cases.
# Uses real Docker containers (starts lightweight sleepers, then kills them).
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# Strip ANSI color codes from output for assertion-friendly text
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ─── Test 1: Kill specific worker by ID ───────────────────────────────────────

setup_test "kill: stop specific worker by ID"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Start a real lightweight container to kill
cname="swarm-test-kill1-$$"
docker run -d --name "$cname" alpine sleep 300 >/dev/null 2>&1
echo "$cname" > "$OUTPUT_DIR/pids/worker-1.cid"

# Verify it's running
running=$(docker inspect --format='{{.State.Running}}' "$cname" 2>/dev/null) || running="false"
[[ "$running" == "true" ]] \
    && pass "container running before kill" \
    || fail "container not running before kill"

# Kill it
output=$(cmd_kill "$OUTPUT_DIR" "worker-1" 2>&1 | strip_ansi)

# Container should be stopped and removed
running=$(docker inspect --format='{{.State.Running}}' "$cname" 2>/dev/null) || running="gone"
[[ "$running" == "gone" ]] \
    && pass "container removed after kill" \
    || fail "container still exists after kill (state=$running)"

# CID file should be cleaned up
assert_file_not_exists "$OUTPUT_DIR/pids/worker-1.cid" "cid file removed"

# Output should confirm the kill
assert_output_contains "$output" "Stopped worker-1" "kill confirmed in output"

teardown_test
trap - EXIT

# ─── Test 2: Kill all workers ─────────────────────────────────────────────────

setup_test "kill: stop all workers"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Start two lightweight containers
cname1="swarm-test-killall1-$$"
cname2="swarm-test-killall2-$$"
docker run -d --name "$cname1" alpine sleep 300 >/dev/null 2>&1
docker run -d --name "$cname2" alpine sleep 300 >/dev/null 2>&1
echo "$cname1" > "$OUTPUT_DIR/pids/worker-1.cid"
echo "$cname2" > "$OUTPUT_DIR/pids/worker-2.cid"

output=$(cmd_kill "$OUTPUT_DIR" 2>&1 | strip_ansi)

# Both containers should be gone
r1=$(docker inspect --format='{{.State.Running}}' "$cname1" 2>/dev/null) || r1="gone"
r2=$(docker inspect --format='{{.State.Running}}' "$cname2" 2>/dev/null) || r2="gone"
[[ "$r1" == "gone" ]] \
    && pass "worker-1 container removed" \
    || fail "worker-1 still exists (state=$r1)"
[[ "$r2" == "gone" ]] \
    && pass "worker-2 container removed" \
    || fail "worker-2 still exists (state=$r2)"

# Both CID files should be gone
assert_file_not_exists "$OUTPUT_DIR/pids/worker-1.cid" "worker-1 cid removed"
assert_file_not_exists "$OUTPUT_DIR/pids/worker-2.cid" "worker-2 cid removed"

teardown_test
trap - EXIT

# ─── Test 3: Kill with missing pids dir ───────────────────────────────────────

setup_test "kill: error when pids directory missing"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Remove pids dir to trigger error
rm -rf "$OUTPUT_DIR/pids"

output=$(cmd_kill "$OUTPUT_DIR" 2>&1 | strip_ansi) || true

assert_output_contains "$output" "No pids directory" "error message for missing pids dir"

teardown_test
trap - EXIT

# ─── Test 4: Kill nonexistent worker ──────────────────────────────────────────

setup_test "kill: error when target worker not found"
trap teardown_test EXIT

init_test_workspace
load_swarm

output=$(cmd_kill "$OUTPUT_DIR" "worker-99" 2>&1 | strip_ansi) || true

assert_output_contains "$output" "No tracking file" "error message for missing worker"

teardown_test
trap - EXIT

# ─── Test 5: Kill already-dead container ──────────────────────────────────────

setup_test "kill: handles already-stopped container gracefully"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Write a cid for a container that doesn't exist
echo "swarm-test-ghost-$$" > "$OUTPUT_DIR/pids/worker-1.cid"

# Should not error out — docker stop/rm failures are swallowed
output=$(cmd_kill "$OUTPUT_DIR" "worker-1" 2>&1 | strip_ansi)

# CID file should still be cleaned up
assert_file_not_exists "$OUTPUT_DIR/pids/worker-1.cid" "cid file removed even for dead container"

assert_output_contains "$output" "Stopped worker-1" "reports stopped even for ghost container"

teardown_test
trap - EXIT

# ─── Test 6: Kill with no output dir ──────────────────────────────────────────

setup_test "kill: error when no output dir provided"
trap teardown_test EXIT

output=$(cmd_kill "" 2>&1 | strip_ansi) || true

assert_output_contains "$output" "Usage" "usage message shown"

teardown_test
trap - EXIT

print_summary
