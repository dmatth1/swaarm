#!/usr/bin/env bash
# Integration tests for rate-limit backoff in docker/entrypoint.sh.
# Runs entrypoint.sh as a real subprocess with PATH-based mocks.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$TESTS_DIR/../docker/entrypoint.sh"
source "$TESTS_DIR/helpers.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Call after init_test_workspace. Sets MOCK_BIN, PROMPTS_DIR (test), WORKER_WORKSPACE.
init_rate_limit_workspace() {
    MOCK_BIN="$TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"

    local prompts_dir="$TEST_TMPDIR/prompts"
    mkdir -p "$prompts_dir"
    printf 'Test worker prompt for {{AGENT_ID}}\n' > "$prompts_dir/worker.md"
    PROMPTS_DIR="$prompts_dir"

    WORKER_WORKSPACE="$TEST_TMPDIR/workspace"
    mkdir -p "$TEST_TMPDIR/logs"
}

# Create a mock claude that returns a rate-limit error for the first N calls,
# then returns ALL_DONE. Call count is tracked via $MOCK_BIN/call_count.
setup_claude_mock() {
    local rate_limit_count="${1:-1}"
    cat > "$MOCK_BIN/claude" << SCRIPT
#!/usr/bin/env bash
count_file="$MOCK_BIN/call_count"
count=\$(cat "\$count_file" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "\$count_file"
if [[ \$count -le $rate_limit_count ]]; then
    echo "Error: rate limit exceeded. Please try again later."
    exit 1
fi
echo "ALL_DONE"
SCRIPT
    chmod +x "$MOCK_BIN/claude"
}

# Create a mock sleep that records each call argument to $MOCK_BIN/sleep_log.
setup_sleep_mock() {
    cat > "$MOCK_BIN/sleep" << SCRIPT
#!/usr/bin/env bash
echo "\$1" >> "$MOCK_BIN/sleep_log"
SCRIPT
    chmod +x "$MOCK_BIN/sleep"
}

# Run entrypoint.sh in worker mode with test env vars and mocked PATH.
run_worker_test() {
    LOGS_DIR="$TEST_TMPDIR/logs" \
    UPSTREAM_DIR="$REPO_DIR" \
    WORKSPACE_DIR="$WORKER_WORKSPACE" \
    PROMPTS_DIR="$PROMPTS_DIR" \
    MULTI_ROUND="false" \
    MAX_WORKER_ITERATIONS="10" \
    PATH="$MOCK_BIN:$PATH" \
        bash "$ENTRYPOINT" worker 1 2>/dev/null || true
}

# ─── Test 1: Single rate-limit → sleep called in [240, 360] ──────────────────

setup_test "rate-limit: single rate-limit triggers sleep in [240, 360]"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
init_rate_limit_workspace
setup_claude_mock 1
setup_sleep_mock

run_worker_test

sleep_log="$MOCK_BIN/sleep_log"
assert_file_exists "$sleep_log" "sleep was called (rate-limit triggered backoff)"

first_sleep=$(grep -v '^2$' "$sleep_log" 2>/dev/null | head -1 || echo "")
[[ -n "$first_sleep" ]] \
    && pass "backoff sleep found (got ${first_sleep}s)" \
    || fail "no backoff sleep found in sleep_log"

if [[ -n "$first_sleep" ]]; then
    [[ "$first_sleep" -ge 240 && "$first_sleep" -le 360 ]] \
        && pass "first sleep in range [240, 360]" \
        || fail "first sleep out of range [240, 360]: got $first_sleep"
fi

teardown_test
trap - EXIT

# ─── Test 2: Two rate-limits → second delay escalates beyond first ────────────

setup_test "rate-limit: delays escalate on consecutive rate-limits"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
init_rate_limit_workspace
setup_claude_mock 2
setup_sleep_mock

run_worker_test

sleep_log="$MOCK_BIN/sleep_log"
# Filter out normal sleep 2 calls; get backoff sleeps only
backoff_sleeps=($(grep -v '^2$' "$sleep_log" 2>/dev/null || true))

[[ "${#backoff_sleeps[@]}" -ge 2 ]] \
    && pass "at least 2 backoff sleeps recorded" \
    || fail "expected 2 backoff sleeps, got ${#backoff_sleeps[@]}"

if [[ "${#backoff_sleeps[@]}" -ge 2 ]]; then
    first="${backoff_sleeps[0]}"
    second="${backoff_sleeps[1]}"
    [[ "$second" -gt "$first" ]] \
        && pass "second delay ($second) > first delay ($first)" \
        || fail "delays did not escalate: first=$first second=$second"
    # Second base is 900s; with jitter [720, 1080]
    [[ "$second" -ge 720 && "$second" -le 1080 ]] \
        && pass "second sleep in range [720, 1080]" \
        || fail "second sleep out of range [720, 1080]: got $second"
fi

teardown_test
trap - EXIT

# ─── Test 3: Non-rate-limit error does not trigger backoff ───────────────────

setup_test "rate-limit: non-rate-limit claude error does not trigger backoff"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
init_rate_limit_workspace

# Claude returns a generic error first, then ALL_DONE
cat > "$MOCK_BIN/claude" << 'SCRIPT'
#!/usr/bin/env bash
count_file="$(dirname "$0")/call_count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$count_file"
if [[ $count -le 1 ]]; then
    echo "Error: unexpected internal error (generic failure)"
    exit 1
fi
echo "ALL_DONE"
SCRIPT
chmod +x "$MOCK_BIN/claude"
setup_sleep_mock

run_worker_test

sleep_log="$MOCK_BIN/sleep_log"
# Only normal sleep 2 calls should be present — no backoff
backoff_sleeps=($(grep -v '^2$' "$sleep_log" 2>/dev/null || true))
[[ "${#backoff_sleeps[@]}" -eq 0 ]] \
    && pass "no backoff sleep triggered for non-rate-limit error" \
    || fail "unexpected backoff sleep for non-rate-limit error: ${backoff_sleeps[*]}"

teardown_test
trap - EXIT

# ─── Test 4: Worker log records [rate-limit] message ─────────────────────────

setup_test "rate-limit: worker log contains [rate-limit] entry"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
init_rate_limit_workspace
setup_claude_mock 1
setup_sleep_mock

run_worker_test

worker_log="$TEST_TMPDIR/logs/worker-1.log"
assert_file_exists "$worker_log" "worker log created"
grep -q "\[rate-limit\]" "$worker_log" \
    && pass "worker log contains [rate-limit] entry" \
    || fail "worker log missing [rate-limit] entry"

teardown_test
trap - EXIT

print_summary
