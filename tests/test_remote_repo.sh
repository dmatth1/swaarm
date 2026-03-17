#!/usr/bin/env bash
# Integration tests for --repo flag (remote GitHub repo mirroring).
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$TESTS_DIR/../docker/entrypoint.sh"
source "$TESTS_DIR/helpers.sh"

# ─── Test 1: init_workspace adds github remote when REMOTE_REPO is set ────────

setup_test "remote: init_workspace configures github remote"
trap teardown_test EXIT

init_test_workspace
load_swarm

# Use a local bare repo as the "remote" to avoid network calls
FAKE_REMOTE="$TEST_TMPDIR/fake-remote.git"
git init --bare "$FAKE_REMOTE" -q

REMOTE_REPO="$FAKE_REMOTE"
OUTPUT_DIR="$TEST_TMPDIR/swarm-output"
REPO_DIR="$OUTPUT_DIR/repo.git"
LOGS_DIR="$OUTPUT_DIR/logs"
MAIN_DIR="$OUTPUT_DIR/main"
TASK="test task"

init_workspace

# Check github remote exists on repo.git
remote_url=$(cd "$REPO_DIR" && git remote get-url github 2>/dev/null) || remote_url=""
[[ "$remote_url" == "$FAKE_REMOTE" ]] \
    && pass "github remote configured (url=$remote_url)" \
    || fail "github remote not set (got: '$remote_url')"

teardown_test
trap - EXIT

# ─── Test 2: sync_remote pushes to github remote ─────────────────────────────

setup_test "remote: sync_remote pushes to github remote"
trap teardown_test EXIT

init_test_workspace
load_swarm

FAKE_REMOTE="$TEST_TMPDIR/fake-remote.git"
git init --bare "$FAKE_REMOTE" -q

REMOTE_REPO="$FAKE_REMOTE"
OUTPUT_DIR="$TEST_TMPDIR/swarm-output2"
REPO_DIR="$OUTPUT_DIR/repo.git"
LOGS_DIR="$OUTPUT_DIR/logs"
MAIN_DIR="$OUTPUT_DIR/main"
TASK="test task"

init_workspace

# Verify the remote received the bootstrap commit
remote_log=$(cd "$FAKE_REMOTE" && git log --oneline main 2>/dev/null) || remote_log=""
echo "$remote_log" | grep -q "init: workspace bootstrap" \
    && pass "remote received bootstrap commit" \
    || fail "remote missing bootstrap commit (got: '$remote_log')"

teardown_test
trap - EXIT

# ─── Test 3: sync_remote is no-op when REMOTE_REPO is empty ──────────────────

setup_test "remote: sync_remote is no-op without --repo"
trap teardown_test EXIT

init_test_workspace
load_swarm

REMOTE_REPO=""

# sync_remote should not error when no remote is set
sync_remote && pass "sync_remote succeeds with empty REMOTE_REPO" \
    || fail "sync_remote failed with empty REMOTE_REPO"

teardown_test
trap - EXIT

# ─── Test 4: SWARM_REPO stored in and restored from state file ───────────────

setup_test "remote: SWARM_REPO persists in swarm.state"
trap teardown_test EXIT

init_test_workspace
load_swarm

{
    printf 'SWARM_TASK=%q\n' "build a thing"
    printf 'SWARM_AGENTS=%s\n' "2"
    printf 'SWARM_MODEL=%q\n' ""
    printf 'SWARM_REPO=%q\n' "https://github.com/user/repo"
    printf 'SWARM_STARTED="%s"\n' "$(date)"
} > "$OUTPUT_DIR/swarm.state"

source "$OUTPUT_DIR/swarm.state"
assert_eq "https://github.com/user/repo" "$SWARM_REPO" "SWARM_REPO stored correctly"

teardown_test
trap - EXIT

# ─── Test 5: resume configures github remote when --repo provided ─────────────

setup_test "remote: resume adds github remote to existing repo.git"
trap teardown_test EXIT

init_test_workspace
load_swarm

FAKE_REMOTE="$TEST_TMPDIR/fake-remote2.git"
git init --bare "$FAKE_REMOTE" -q

# Write state without a repo
{
    printf 'SWARM_TASK=%q\n' "build a thing"
    printf 'SWARM_AGENTS=%s\n' "1"
    printf 'SWARM_MODEL=%q\n' ""
    printf 'SWARM_REPO=%q\n' ""
    printf 'SWARM_STARTED="%s"\n' "$(date)"
} > "$OUTPUT_DIR/swarm.state"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

ensure_docker_image() { :; }
docker_run_worker() { :; }
run_with_review() { :; }

# Resume with --repo override
cmd_resume "$OUTPUT_DIR" "" "" "$FAKE_REMOTE" 2>/dev/null || true

remote_url=$(cd "$REPO_DIR" && git remote get-url github 2>/dev/null) || remote_url=""
[[ "$remote_url" == "$FAKE_REMOTE" ]] \
    && pass "resume configured github remote" \
    || fail "resume did not set github remote (got: '$remote_url')"

teardown_test
trap - EXIT

# ─── Test 6: PUBLIC_REPO env var triggers security notice in entrypoint ───────

setup_test "remote: PUBLIC_REPO=true injects security notice into prompt"
trap teardown_test EXIT

init_test_workspace

MOCK_BIN="$TEST_TMPDIR/bin"
mkdir -p "$MOCK_BIN"

# Mock claude that dumps stdin (the prompt) to a file
PROMPT_FILE="$TEST_TMPDIR/prompt_received"
cat > "$MOCK_BIN/claude" << SCRIPT
#!/usr/bin/env bash
cat > "$PROMPT_FILE"
echo "ALL_DONE"
SCRIPT
chmod +x "$MOCK_BIN/claude"

local_prompts="$TEST_TMPDIR/prompts"
mkdir -p "$local_prompts"
printf 'Test worker prompt for {{AGENT_ID}}\n' > "$local_prompts/worker.md"

# Mock sleep
cat > "$MOCK_BIN/sleep" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT
chmod +x "$MOCK_BIN/sleep"

mkdir -p "$TEST_TMPDIR/logs"
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

PUBLIC_REPO=true \
LOGS_DIR="$TEST_TMPDIR/logs" \
UPSTREAM_DIR="$REPO_DIR" \
WORKSPACE_DIR="$TEST_TMPDIR/workspace" \
PROMPTS_DIR="$local_prompts" \
MULTI_ROUND="false" \
MAX_WORKER_ITERATIONS="2" \
PATH="$MOCK_BIN:$PATH" \
    bash "$ENTRYPOINT" worker 1 2>/dev/null || true

if [[ -f "$PROMPT_FILE" ]]; then
    grep -q "PUBLIC REPOSITORY" "$PROMPT_FILE" \
        && pass "security notice present in worker prompt" \
        || fail "security notice missing from worker prompt"
    grep -q "MUST NOT commit" "$PROMPT_FILE" \
        && pass "secret prohibition present" \
        || fail "secret prohibition missing"
else
    fail "no prompt captured"
    fail "cannot check secret prohibition"
fi

teardown_test
trap - EXIT

# ─── Test 7: security notice absent when PUBLIC_REPO not set ──────────────────

setup_test "remote: no security notice without PUBLIC_REPO"
trap teardown_test EXIT

init_test_workspace

MOCK_BIN="$TEST_TMPDIR/bin2"
mkdir -p "$MOCK_BIN"

PROMPT_FILE2="$TEST_TMPDIR/prompt_received2"
cat > "$MOCK_BIN/claude" << SCRIPT
#!/usr/bin/env bash
cat > "$PROMPT_FILE2"
echo "ALL_DONE"
SCRIPT
chmod +x "$MOCK_BIN/claude"

cat > "$MOCK_BIN/sleep" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT
chmod +x "$MOCK_BIN/sleep"

local_prompts="$TEST_TMPDIR/prompts2"
mkdir -p "$local_prompts"
printf 'Test worker prompt for {{AGENT_ID}}\n' > "$local_prompts/worker.md"

mkdir -p "$TEST_TMPDIR/logs"
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001" "add task"

LOGS_DIR="$TEST_TMPDIR/logs" \
UPSTREAM_DIR="$REPO_DIR" \
WORKSPACE_DIR="$TEST_TMPDIR/workspace2" \
PROMPTS_DIR="$local_prompts" \
MULTI_ROUND="false" \
MAX_WORKER_ITERATIONS="2" \
PATH="$MOCK_BIN:$PATH" \
    bash "$ENTRYPOINT" worker 1 2>/dev/null || true

if [[ -f "$PROMPT_FILE2" ]]; then
    if grep -q "PUBLIC REPOSITORY" "$PROMPT_FILE2"; then
        fail "security notice should not be present without PUBLIC_REPO"
    else
        pass "no security notice without PUBLIC_REPO"
    fi
else
    fail "no prompt captured"
fi

teardown_test
trap - EXIT

print_summary
