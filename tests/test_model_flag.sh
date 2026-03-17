#!/usr/bin/env bash
# Integration tests for --model flag passthrough.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$TESTS_DIR/../docker/entrypoint.sh"
source "$TESTS_DIR/helpers.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────

MOCK_BIN=""
TEST_LOGS=""

init_model_workspace() {
    MOCK_BIN="$TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"
    TEST_LOGS="$TEST_TMPDIR/logs"
    mkdir -p "$TEST_LOGS"

    local prompts_dir="$TEST_TMPDIR/prompts"
    init_mock_prompts "$prompts_dir"
    printf 'Test worker prompt for {{AGENT_ID}}\n' > "$prompts_dir/worker.md"
    printf 'Orchestrator prompt: {{TASK}} next={{NEXT_TASK_NUM}}\n' > "$prompts_dir/orchestrator.md"
    PROMPTS_DIR="$prompts_dir"
}

# Create a mock claude that records its args and exits.
setup_claude_mock() {
    cat > "$MOCK_BIN/claude" << 'SCRIPT'
#!/usr/bin/env bash
echo "$@" >> "$(dirname "$0")/claude_args"
echo "ALL_DONE"
SCRIPT
    chmod +x "$MOCK_BIN/claude"
}

setup_sleep_mock() {
    cat > "$MOCK_BIN/sleep" << 'SCRIPT'
#!/usr/bin/env bash
# no-op
SCRIPT
    chmod +x "$MOCK_BIN/sleep"
}

# ─── Test 1: Worker passes --model to claude when MODEL is set ────────────────

setup_test "model: worker passes --model to claude CLI"
trap teardown_test EXIT

init_test_workspace
init_model_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
setup_claude_mock
setup_sleep_mock

MODEL="opus" \
LOGS_DIR="$TEST_LOGS" \
UPSTREAM_DIR="$REPO_DIR" \
WORKSPACE_DIR="$TEST_TMPDIR/workspace" \
PROMPTS_DIR="$PROMPTS_DIR" \
MULTI_ROUND="false" \
MAX_WORKER_ITERATIONS="2" \
PATH="$MOCK_BIN:$PATH" \
    bash "$ENTRYPOINT" worker 1 2>/dev/null || true

args_file="$MOCK_BIN/claude_args"
assert_file_exists "$args_file" "claude was called"

grep -q "\-\-model opus" "$args_file" \
    && pass "claude called with --model opus" \
    || fail "claude args missing --model opus (got: $(cat "$args_file"))"

teardown_test
trap - EXIT

# ─── Test 2: Worker omits --model when MODEL is empty ────────────────────────

setup_test "model: worker omits --model when not set"
trap teardown_test EXIT

init_test_workspace
init_model_workspace
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"
setup_claude_mock
setup_sleep_mock

LOGS_DIR="$TEST_LOGS" \
UPSTREAM_DIR="$REPO_DIR" \
WORKSPACE_DIR="$TEST_TMPDIR/workspace2" \
PROMPTS_DIR="$PROMPTS_DIR" \
MULTI_ROUND="false" \
MAX_WORKER_ITERATIONS="2" \
PATH="$MOCK_BIN:$PATH" \
    bash "$ENTRYPOINT" worker 1 2>/dev/null || true

args_file="$MOCK_BIN/claude_args"
assert_file_exists "$args_file" "claude was called"

if grep -q "\-\-model" "$args_file"; then
    fail "claude should not have --model when MODEL is empty (got: $(cat "$args_file"))"
else
    pass "claude called without --model"
fi

teardown_test
trap - EXIT

# ─── Test 3: Orchestrator augment passes --model to claude ────────────────────

setup_test "model: orchestrator augment passes --model to claude CLI"
trap teardown_test EXIT

init_test_workspace
init_model_workspace
setup_claude_mock

MODEL="sonnet" \
TASK="add tests" \
NEXT_TASK_NUM="1" \
LOGS_DIR="$TEST_LOGS" \
UPSTREAM_DIR="$REPO_DIR" \
WORKSPACE_DIR="$TEST_TMPDIR/workspace3" \
PROMPTS_DIR="$PROMPTS_DIR" \
PATH="$MOCK_BIN:$PATH" \
    bash "$ENTRYPOINT" orchestrator 2>/dev/null || true

args_file="$MOCK_BIN/claude_args"
assert_file_exists "$args_file" "claude was called"

grep -q "\-\-model sonnet" "$args_file" \
    && pass "orchestrator augment claude called with --model sonnet" \
    || fail "orchestrator augment claude args missing --model sonnet (got: $(cat "$args_file"))"

teardown_test
trap - EXIT

# ─── Test 4: --model stored in swarm.state and restored on resume ─────────────

setup_test "model: --model stored in swarm.state"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Simulate what main() writes to swarm.state
MODEL="opus"
{
    printf 'SWARM_TASK=%q\n' "build a thing"
    printf 'SWARM_AGENTS=%s\n' "2"
    printf 'SWARM_MODEL=%q\n' "$MODEL"
    printf 'SWARM_STARTED="%s"\n' "$(date)"
} > "$OUTPUT_DIR/swarm.state"

# Source the state file and check
source "$OUTPUT_DIR/swarm.state"
assert_eq "opus" "$SWARM_MODEL" "SWARM_MODEL stored as opus"

teardown_test
trap - EXIT

# ─── Test 5: resume reads model from state file ──────────────────────────────

setup_test "model: resume reads SWARM_MODEL from state file"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Write state with model
{
    printf 'SWARM_TASK=%q\n' "build a thing"
    printf 'SWARM_AGENTS=%s\n' "1"
    printf 'SWARM_MODEL=%q\n' "opus"
    printf 'SWARM_STARTED="%s"\n' "$(date)"
} > "$OUTPUT_DIR/swarm.state"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

# Mock docker and run_with_review to capture MODEL value
ensure_docker_image() { :; }
docker_run_worker() { :; }
run_with_review() {
    echo "MODEL=$MODEL" > "$TEST_TMPDIR/resume_model"
}

output=$(cmd_resume "$OUTPUT_DIR" "" "" 2>&1) || true

assert_file_exists "$TEST_TMPDIR/resume_model" "run_with_review was called"
grep -q "MODEL=opus" "$TEST_TMPDIR/resume_model" \
    && pass "resume restored MODEL=opus from state file" \
    || fail "MODEL not restored (got: $(cat "$TEST_TMPDIR/resume_model"))"

teardown_test
trap - EXIT

# ─── Test 6: resume --model overrides state file model ────────────────────────

setup_test "model: resume --model overrides SWARM_MODEL"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Write state with model=sonnet
{
    printf 'SWARM_TASK=%q\n' "build a thing"
    printf 'SWARM_AGENTS=%s\n' "1"
    printf 'SWARM_MODEL=%q\n' "sonnet"
    printf 'SWARM_STARTED="%s"\n' "$(date)"
} > "$OUTPUT_DIR/swarm.state"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

ensure_docker_image() { :; }
docker_run_worker() { :; }
run_with_review() {
    echo "MODEL=$MODEL" > "$TEST_TMPDIR/resume_model"
}

# Pass override_model="opus" as third argument
output=$(cmd_resume "$OUTPUT_DIR" "" "opus" 2>&1) || true

assert_file_exists "$TEST_TMPDIR/resume_model" "run_with_review was called"
grep -q "MODEL=opus" "$TEST_TMPDIR/resume_model" \
    && pass "resume --model opus overrides state file sonnet" \
    || fail "MODEL override failed (got: $(cat "$TEST_TMPDIR/resume_model"))"

teardown_test
trap - EXIT

# ─── Test 7: all claude calls in entrypoint use CLAUDE_MODEL_FLAG ─────────────

setup_test "model: all entrypoint claude calls use CLAUDE_MODEL_FLAG"
trap teardown_test EXIT

# All roles must call run_claude (which uses CLAUDE_MODEL_FLAG internally)
role_calls=$(grep -c 'run_claude "\$prompt"' "$ENTRYPOINT" 2>/dev/null) || role_calls=0
[[ "$role_calls" -ge 4 ]] \
    && pass "all 4 roles call run_claude which passes CLAUDE_MODEL_FLAG ($role_calls calls)" \
    || fail "expected at least 4 run_claude calls, found $role_calls"

# Verify run_claude uses CLAUDE_MODEL_FLAG
grep -q 'CLAUDE_MODEL_FLAG' "$ENTRYPOINT" \
    && pass "run_claude uses CLAUDE_MODEL_FLAG" \
    || fail "run_claude missing CLAUDE_MODEL_FLAG"

teardown_test
trap - EXIT

print_summary
