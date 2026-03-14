# Rate-Limit Backoff Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a worker container's `claude` call is rate-limited, keep the task claimed, sleep with exponential backoff (5m→15m→30m→1hr→2hr→4hr ±20% jitter), and automatically retry instead of spinning or crashing.

**Architecture:** All changes live in `docker/entrypoint.sh`. Rate-limit detection greps the claude output after each call; on a match the worker sleeps and `continue`s the loop (task stays in `tasks/active/`). A `rate_limit_attempts` counter tracks escalation and resets to 0 after any successful call. Four env vars (`LOGS_DIR`, `UPSTREAM_DIR`, `WORKSPACE_DIR`, `PROMPTS_DIR`) make the entrypoint testable without Docker. Tests run the entrypoint as a real subprocess with PATH-based mocks for `claude` and `sleep`.

**Tech Stack:** bash 5+, existing `tests/helpers.sh` infrastructure

---

## Chunk 1: Implementation + tests

**Files:**
- Modify: `docker/entrypoint.sh` — add env var overrides for testability + rate-limit backoff in `run_worker`
- Create: `tests/test_rate_limit.sh` — subprocess-based tests for backoff behavior

---

### Task 1: Add env var overrides and rate-limit backoff to entrypoint.sh

**Files:**
- Modify: `docker/entrypoint.sh`

The four env vars (`LOGS_DIR`, `UPSTREAM_DIR`, `WORKSPACE_DIR`, `PROMPTS_DIR`) all default to their current hardcoded values, so Docker behavior is unchanged.

- [ ] **Step 1: Write failing test — rate-limit triggers sleep**

Create `tests/test_rate_limit.sh` with just Test 1 (add the rest in Task 2):

```bash
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

print_summary
```

- [ ] **Step 2: Make executable and run to verify it fails**

```bash
chmod +x tests/test_rate_limit.sh
bash tests/test_rate_limit.sh
```
Expected: FAIL — "sleep was called" fails because `sleep` is the real binary (not recording) and no backoff logic exists yet.

- [ ] **Step 3: Implement env var overrides in entrypoint.sh**

Read `docker/entrypoint.sh` fully, then make the following substitutions:

In `run_worker`:
```bash
# Change line:
local log_file="/logs/${worker_name}.log"
# To:
local log_file="${LOGS_DIR:-/logs}/${worker_name}.log"
```

```bash
# Change line:
git clone /upstream /workspace -q 2>/dev/null
# To:
git clone "${UPSTREAM_DIR:-/upstream}" "${WORKSPACE_DIR:-/workspace}" -q 2>/dev/null
```

```bash
# Change line:
cd /workspace
# To:
cd "${WORKSPACE_DIR:-/workspace}"
```

```bash
# Change line:
prompt=$(sed "s|{{AGENT_ID}}|${worker_name}|g" /prompts/worker.md)
# To:
prompt=$(sed "s|{{AGENT_ID}}|${worker_name}|g" "${PROMPTS_DIR:-/prompts}/worker.md")
```

- [ ] **Step 4: Add rate-limit backoff in run_worker**

Add `rate_limit_attempts` counter and backoff array immediately after the `local iteration=0` line:

```bash
local iteration=0
local rate_limit_attempts=0
local -a backoff_delays=(300 900 1800 3600 7200 14400)
```

After the **closing `fi`** of the entire verbose/non-verbose output-capture block (the `if [[ "$verbose" == "true" ]]; then ... fi` that wraps both claude call branches), add rate-limit detection **before** the signal-word check. The structure should be:

```bash
        # Run one agent session
        local output
        if [[ "$verbose" == "true" ]]; then
            output=$(echo "$prompt" | claude --dangerously-skip-permissions -p 2>&1 | tee -a "$log_file") || true
        else
            output=$(echo "$prompt" | claude --dangerously-skip-permissions -p 2>&1) || true
            echo "$output" >> "$log_file"
        fi

        # ↓ INSERT HERE — after the fi above, before the signal-word check below

        # Check for rate-limit — keep task claimed, sleep, retry
        ...

        # Check completion signals   ← existing line, do not move
        if echo "$output" | grep -q ...
```

The rate-limit block to insert:

```bash
        # Check for rate-limit — keep task claimed, sleep, retry
        if echo "$output" | grep -qi "rate limit\|too many requests\|quota exceeded\|429"; then
            local delay_idx=$(( rate_limit_attempts < ${#backoff_delays[@]} ? rate_limit_attempts : ${#backoff_delays[@]} - 1 ))
            local base_delay="${backoff_delays[$delay_idx]}"
            local jitter=$(( (RANDOM % 41) + 80 ))
            local sleep_secs=$(( base_delay * jitter / 100 ))
            rate_limit_attempts=$(( rate_limit_attempts + 1 ))
            echo "[rate-limit] attempt ${rate_limit_attempts}, sleeping ${sleep_secs}s (base=${base_delay}s, jitter=${jitter}%)" >> "$log_file"
            sleep "$sleep_secs"
            continue
        fi

        # Successful call — reset rate-limit backoff counter
        rate_limit_attempts=0
```

- [ ] **Step 5: Run Test 1 to verify it passes**

```bash
bash tests/test_rate_limit.sh
```
Expected: `1/1 passed`

- [ ] **Step 6: Commit**

```bash
git add docker/entrypoint.sh tests/test_rate_limit.sh
git commit -m "feat: add rate-limit backoff in worker (exponential, ±20% jitter)"
```

---

### Task 2: Complete the test suite

**Files:**
- Modify: `tests/test_rate_limit.sh` — add Tests 2–4
- Modify: `tests/run_tests.sh` — register new suite

- [ ] **Step 1: Add Tests 2–4 to test_rate_limit.sh**

Replace the `print_summary` at the bottom with the following three tests, then re-add `print_summary` at the very end:

```bash
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
    echo "Error: unexpected internal error (not a rate limit)"
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
```

- [ ] **Step 2: Run the full rate-limit suite**

```bash
bash tests/test_rate_limit.sh
```
Expected: `4/4 passed` (all four tests pass)

- [ ] **Step 3: Run full suite**

`tests/run_tests.sh` auto-discovers all `test_*.sh` files — no registration needed. The new suite will be picked up automatically.

```bash
bash tests/run_tests.sh
```
Expected: all suites pass (existing 7 + new rate_limit suite)

- [ ] **Step 4: Commit**

```bash
git add tests/test_rate_limit.sh
git commit -m "test: add rate-limit backoff tests (single, escalation, non-rate-limit, log)"
```
