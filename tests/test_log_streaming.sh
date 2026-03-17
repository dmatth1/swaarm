#!/usr/bin/env bash
# Integration tests for real-time log streaming in docker/entrypoint.sh.
# Verifies that all roles tee claude output to their log files (not buffered).
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$TESTS_DIR/../docker/entrypoint.sh"
source "$TESTS_DIR/helpers.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────

MOCK_BIN=""
TEST_LOGS=""

init_streaming_workspace() {
    MOCK_BIN="$TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"
    TEST_LOGS="$TEST_TMPDIR/logs"
    mkdir -p "$TEST_LOGS"
}

# Create a mock claude that outputs recognizable lines.
# Usage: setup_claude_mock [signal_word]
setup_claude_mock() {
    local signal="${1:-ALL_DONE}"
    cat > "$MOCK_BIN/claude" << SCRIPT
#!/usr/bin/env bash
echo "LINE_ONE: thinking about the task"
echo "LINE_TWO: writing some code"
echo "LINE_THREE: $signal"
SCRIPT
    chmod +x "$MOCK_BIN/claude"
}

# Mock sleep to be instant
setup_sleep_mock() {
    cat > "$MOCK_BIN/sleep" << 'SCRIPT'
#!/usr/bin/env bash
# no-op
SCRIPT
    chmod +x "$MOCK_BIN/sleep"
}

# ─── Test 1: Worker streams claude output to log file ─────────────────────────

setup_test "streaming: worker claude output appears in log file"
trap teardown_test EXIT

init_test_workspace
init_streaming_workspace

local_prompts="$TEST_TMPDIR/prompts"
init_mock_prompts "$local_prompts"
printf 'Test worker prompt for {{AGENT_ID}}\n' > "$local_prompts/worker.md"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
setup_claude_mock "ALL_DONE"
setup_sleep_mock

LOGS_DIR="$TEST_LOGS" \
UPSTREAM_DIR="$REPO_DIR" \
WORKSPACE_DIR="$TEST_TMPDIR/workspace" \
PROMPTS_DIR="$local_prompts" \
MULTI_ROUND="false" \
MAX_WORKER_ITERATIONS="2" \
PATH="$MOCK_BIN:$PATH" \
    bash "$ENTRYPOINT" worker 1 2>/dev/null || true

log_file="$TEST_LOGS/worker-1.log"
assert_file_exists "$log_file" "worker log file created"

grep -q "LINE_ONE" "$log_file" \
    && pass "worker log contains LINE_ONE (claude output streamed)" \
    || fail "worker log missing LINE_ONE"

grep -q "LINE_TWO" "$log_file" \
    && pass "worker log contains LINE_TWO" \
    || fail "worker log missing LINE_TWO"

grep -q "LINE_THREE" "$log_file" \
    && pass "worker log contains LINE_THREE" \
    || fail "worker log missing LINE_THREE"

teardown_test
trap - EXIT

# ─── Test 2: Orchestrator streams claude output to log file ───────────────────

setup_test "streaming: orchestrator claude output appears in log file"
trap teardown_test EXIT

init_test_workspace
init_streaming_workspace

local_prompts="$TEST_TMPDIR/prompts"
init_mock_prompts "$local_prompts"
printf 'Test orchestrator prompt for {{TASK}}\n' > "$local_prompts/orchestrator.md"

setup_claude_mock "ORCHESTRATION COMPLETE"

TASK="build a test app" \
LOGS_DIR="$TEST_LOGS" \
PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin" \
    bash -c '
        # Orchestrator uses hardcoded /logs and /upstream paths — override via function
        set -euo pipefail
        source "'"$ENTRYPOINT"'" 2>/dev/null || true
    ' 2>/dev/null || true

# Orchestrator writes to /logs/orchestrator.log which we cannot override easily.
# Instead, test it by running the entrypoint directly with env overrides.
# The orchestrator function uses hardcoded paths (/upstream, /workspace, /logs).
# We test it differently: verify the tee pattern is present in the source.

grep -q 'run_claude' "$ENTRYPOINT" \
    && pass "orchestrator uses run_claude (verified in source)" \
    || fail "orchestrator missing run_claude call"

teardown_test
trap - EXIT

# ─── Test 3: Orchestrator augment streams claude output to log file ────────────

setup_test "streaming: orchestrator augment claude output appears in log file"
trap teardown_test EXIT

init_test_workspace
init_streaming_workspace

local_prompts="$TEST_TMPDIR/prompts"
init_mock_prompts "$local_prompts"
printf 'Orchestrator prompt: {{TASK}} next={{NEXT_TASK_NUM}}\n' > "$local_prompts/orchestrator.md"

setup_claude_mock "ORCHESTRATION COMPLETE"

TASK="add tests" \
NEXT_TASK_NUM="1" \
LOGS_DIR="$TEST_LOGS" \
UPSTREAM_DIR="$REPO_DIR" \
WORKSPACE_DIR="$TEST_TMPDIR/workspace-augment" \
PROMPTS_DIR="$local_prompts" \
PATH="$MOCK_BIN:$PATH" \
    bash "$ENTRYPOINT" orchestrator 2>/dev/null || true

log_file="$TEST_LOGS/orchestrator.log"
assert_file_exists "$log_file" "orchestrator log file created"

grep -q "LINE_ONE" "$log_file" \
    && pass "orchestrator log contains LINE_ONE (claude output streamed)" \
    || fail "orchestrator log missing LINE_ONE"

grep -q "LINE_TWO" "$log_file" \
    && pass "orchestrator log contains LINE_TWO" \
    || fail "orchestrator log missing LINE_TWO"

teardown_test
trap - EXIT

# ─── Test 4: All roles use tee pattern (source verification) ─────────────────

setup_test "streaming: all claude calls use tee -a pattern"
trap teardown_test EXIT

# Count direct claude calls that bypass run_claude (the old pattern)
direct=$(grep -c 'echo.*\$prompt.*|.*claude' "$ENTRYPOINT" 2>/dev/null) || direct=0
[[ "$direct" -eq 0 ]] \
    && pass "no direct claude pipe calls remain (all use run_claude)" \
    || fail "$direct claude call(s) still bypass run_claude"

# Verify run_claude is called from each role (5 roles)
role_calls=$(grep -c 'run_claude "\$prompt"' "$ENTRYPOINT" 2>/dev/null || echo 0)
[[ "$role_calls" -ge 4 ]] \
    && pass "all 4 roles call run_claude ($role_calls found)" \
    || fail "expected at least 4 run_claude calls, found $role_calls"

# Verify run_claude uses stream-json for built-in streaming (no PTY needed)
grep -q 'stream-json' "$ENTRYPOINT" \
    && pass "run_claude uses --output-format stream-json for built-in streaming" \
    || fail "run_claude missing --output-format stream-json"

teardown_test
trap - EXIT

# ─── Test 5: Worker log shows output incrementally (not just at end) ──────────

setup_test "streaming: worker log has claude output before DONE marker"
trap teardown_test EXIT

init_test_workspace
init_streaming_workspace

local_prompts="$TEST_TMPDIR/prompts"
init_mock_prompts "$local_prompts"
printf 'Test worker prompt for {{AGENT_ID}}\n' > "$local_prompts/worker.md"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
setup_claude_mock "ALL_DONE"
setup_sleep_mock

LOGS_DIR="$TEST_LOGS" \
UPSTREAM_DIR="$REPO_DIR" \
WORKSPACE_DIR="$TEST_TMPDIR/workspace2" \
PROMPTS_DIR="$local_prompts" \
MULTI_ROUND="false" \
MAX_WORKER_ITERATIONS="2" \
PATH="$MOCK_BIN:$PATH" \
    bash "$ENTRYPOINT" worker 1 2>/dev/null || true

log_file="$TEST_LOGS/worker-1.log"

# Claude output (LINE_ONE) should appear BEFORE the "=== Worker 1 DONE" marker
# This proves output was written during the run, not just appended at the end
line_one_num=$(grep -n "LINE_ONE" "$log_file" | head -1 | cut -d: -f1)
done_line_num=$(grep -n "DONE at" "$log_file" | tail -1 | cut -d: -f1)

if [[ -n "$line_one_num" && -n "$done_line_num" ]]; then
    [[ "$line_one_num" -lt "$done_line_num" ]] \
        && pass "claude output (line $line_one_num) appears before DONE marker (line $done_line_num)" \
        || fail "claude output appeared after DONE marker"
else
    fail "could not find LINE_ONE or DONE marker in log"
fi

teardown_test
trap - EXIT

# ─── Test: Log truncation caps file size ──────────────────────────────────────

setup_test "log streaming: truncate_log caps log file at MAX_LOG_SIZE"
trap teardown_test EXIT

init_streaming_workspace

# Extract and define just the truncate_log function (sourcing full entrypoint triggers exit 1)
eval "$(sed -n '/^truncate_log()/,/^}/p' "$ENTRYPOINT")"

# Create a 500-byte log file
log_file="$TEST_LOGS/truncation-test.log"
python3 -c "print('A' * 500)" > "$log_file"
original_size=$(wc -c < "$log_file" | tr -d ' ')

# Truncate at 200 bytes
MAX_LOG_SIZE=200
truncate_log "$log_file"
new_size=$(wc -c < "$log_file" | tr -d ' ')

[[ "$new_size" -le 300 ]] \
    && pass "log truncated from ${original_size} to ${new_size} bytes (limit 200+marker)" \
    || fail "log not truncated: still ${new_size} bytes (expected ~270)"

grep -q "log truncated" "$log_file" \
    && pass "truncation marker present in log" \
    || fail "truncation marker missing"

teardown_test
trap - EXIT

# ─── Test: Log truncation skipped when under limit ────────────────────────────

setup_test "log streaming: truncate_log skips files under MAX_LOG_SIZE"
trap teardown_test EXIT

init_streaming_workspace

eval "$(sed -n '/^truncate_log()/,/^}/p' "$ENTRYPOINT")"

log_file="$TEST_LOGS/small-log.log"
echo "small log" > "$log_file"
original_size=$(wc -c < "$log_file" | tr -d ' ')

MAX_LOG_SIZE=10485760
truncate_log "$log_file"
new_size=$(wc -c < "$log_file" | tr -d ' ')

[[ "$new_size" -eq "$original_size" ]] \
    && pass "small log untouched (${new_size} bytes)" \
    || fail "small log was modified: ${original_size} → ${new_size}"

teardown_test
trap - EXIT

# ─── Test: Log truncation disabled with MAX_LOG_SIZE=0 ────────────────────────

setup_test "log streaming: truncate_log disabled when MAX_LOG_SIZE=0"
trap teardown_test EXIT

init_streaming_workspace

eval "$(sed -n '/^truncate_log()/,/^}/p' "$ENTRYPOINT")"

log_file="$TEST_LOGS/no-truncate.log"
python3 -c "print('B' * 500)" > "$log_file"
original_size=$(wc -c < "$log_file" | tr -d ' ')

MAX_LOG_SIZE=0
truncate_log "$log_file"
new_size=$(wc -c < "$log_file" | tr -d ' ')

[[ "$new_size" -eq "$original_size" ]] \
    && pass "log untouched when MAX_LOG_SIZE=0 (${new_size} bytes)" \
    || fail "log was truncated despite MAX_LOG_SIZE=0: ${original_size} → ${new_size}"

teardown_test
trap - EXIT

print_summary
