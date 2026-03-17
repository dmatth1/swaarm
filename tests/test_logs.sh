#!/usr/bin/env bash
# Integration tests for cmd_logs.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ─── Test 1: missing output_dir → error ──────────────────────────────────────

setup_test "logs: missing output_dir exits with error"
trap teardown_test EXIT

init_test_workspace
load_swarm

output=$(cmd_logs "" 2>&1) && status=0 || status=$?

[[ "$status" -ne 0 ]] \
    && pass "exits non-zero on missing output_dir" \
    || fail "should have exited non-zero"

echo "$output" | grep -q "Usage:" \
    && pass "prints Usage on missing output_dir" \
    || fail "no Usage message"

teardown_test
trap - EXIT

# ─── Test 2: missing logs dir → error ────────────────────────────────────────

setup_test "logs: missing logs directory exits with error"
trap teardown_test EXIT

init_test_workspace
load_swarm

rm -rf "$LOGS_DIR"

output=$(cmd_logs "$OUTPUT_DIR" 2>&1) && status=0 || status=$?

[[ "$status" -ne 0 ]] \
    && pass "exits non-zero when logs dir missing" \
    || fail "should have exited non-zero"

teardown_test
trap - EXIT

# ─── Test 3: specific worker log not found → lists available ─────────────────

setup_test "logs: missing worker log shows available logs"
trap teardown_test EXIT

init_test_workspace
load_swarm

mkdir -p "$LOGS_DIR"
echo "some log" > "$LOGS_DIR/worker-1.log"

output=$(cmd_logs "$OUTPUT_DIR" "worker-99" 2>&1) && status=0 || status=$?

[[ "$status" -ne 0 ]] \
    && pass "exits non-zero for missing log" \
    || fail "should have exited non-zero"

echo "$output" | grep -q "worker-1" \
    && pass "lists available log files" \
    || fail "did not list available logs"

teardown_test
trap - EXIT

# ─── Test 4: no log files → error ───────────────────────────────────────────

setup_test "logs: empty logs directory exits with error"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Remove any log files but keep the directory
rm -f "$LOGS_DIR"/*.log 2>/dev/null || true

output=$(cmd_logs "$OUTPUT_DIR" 2>&1) && status=0 || status=$?

[[ "$status" -ne 0 ]] \
    && pass "exits non-zero when no log files" \
    || fail "should have exited non-zero"

teardown_test
trap - EXIT

print_summary
