#!/usr/bin/env bash
# Tests for swarm-setup.sh — workspace init, auth extraction, resume mode.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$TESTS_DIR/../swarm-setup.sh"

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=""
setup_test() {
    TEST_TMPDIR=$(mktemp -d)
    echo -e "${YELLOW}▶ $1${NC}"
}
teardown_test() {
    [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
    TEST_TMPDIR=""
}

# ─── Test 1: New workspace creates correct structure ──────────────────────────

setup_test "setup: new workspace creates correct directory structure"
trap teardown_test EXIT

output_dir="$TEST_TMPDIR/test-run"
result=$(bash "$SETUP_SCRIPT" "$output_dir" --new 2>/dev/null)

[[ -d "$output_dir/repo.git" ]] \
    && pass "repo.git created" \
    || fail "repo.git not found"

[[ -d "$output_dir/main" ]] \
    && pass "main clone created" \
    || fail "main clone not found"

[[ -d "$output_dir/logs" ]] \
    && pass "logs dir created" \
    || fail "logs dir not found"

[[ -d "$output_dir/main/tasks/pending" ]] \
    && pass "tasks/pending created" \
    || fail "tasks/pending not found"

[[ -d "$output_dir/main/tasks/active" ]] \
    && pass "tasks/active created" \
    || fail "tasks/active not found"

[[ -d "$output_dir/main/tasks/done" ]] \
    && pass "tasks/done created" \
    || fail "tasks/done not found"

[[ -f "$output_dir/main/SPEC.md" ]] \
    && pass "SPEC.md created" \
    || fail "SPEC.md not found"

[[ -f "$output_dir/main/PROGRESS.md" ]] \
    && pass "PROGRESS.md created" \
    || fail "PROGRESS.md not found"

teardown_test
trap - EXIT

# ─── Test 2: Config output contains required vars ────────────────────────────

setup_test "setup: config output contains all required variables"
trap teardown_test EXIT

output_dir="$TEST_TMPDIR/test-run"
result=$(bash "$SETUP_SCRIPT" "$output_dir" --new 2>/dev/null)

echo "$result" | grep -q "SWARM_OUTPUT_DIR=" \
    && pass "SWARM_OUTPUT_DIR present" \
    || fail "SWARM_OUTPUT_DIR missing"

echo "$result" | grep -q "SWARM_REPO_DIR=" \
    && pass "SWARM_REPO_DIR present" \
    || fail "SWARM_REPO_DIR missing"

echo "$result" | grep -q "SWARM_MAIN_DIR=" \
    && pass "SWARM_MAIN_DIR present" \
    || fail "SWARM_MAIN_DIR missing"

echo "$result" | grep -q "SWARM_LOGS_DIR=" \
    && pass "SWARM_LOGS_DIR present" \
    || fail "SWARM_LOGS_DIR missing"

echo "$result" | grep -q "SWARM_OAUTH_TOKEN=" \
    && pass "SWARM_OAUTH_TOKEN present" \
    || fail "SWARM_OAUTH_TOKEN missing"

echo "$result" | grep -q "SWARM_PROMPTS_DIR=" \
    && pass "SWARM_PROMPTS_DIR present" \
    || fail "SWARM_PROMPTS_DIR missing"

teardown_test
trap - EXIT

# ─── Test 3: Resume mode skips workspace init ────────────────────────────────

setup_test "setup: resume mode skips workspace init"
trap teardown_test EXIT

# Create a workspace first
output_dir="$TEST_TMPDIR/test-run"
bash "$SETUP_SCRIPT" "$output_dir" --new >/dev/null 2>&1

# Touch a marker file to prove init doesn't re-run
echo "marker" > "$output_dir/main/MARKER.txt"

# Resume should not overwrite
result=$(bash "$SETUP_SCRIPT" "$output_dir" --resume 2>/dev/null)

[[ -f "$output_dir/main/MARKER.txt" ]] \
    && pass "marker file preserved (no re-init)" \
    || fail "marker file gone (workspace was re-initialized)"

echo "$result" | grep -q "SWARM_OAUTH_TOKEN=" \
    && pass "config vars still output on resume" \
    || fail "config vars missing on resume"

teardown_test
trap - EXIT

# ─── Test 4: New run fails if directory already exists ───────────────────────

setup_test "setup: new run fails if output directory already has tasks"
trap teardown_test EXIT

output_dir="$TEST_TMPDIR/test-run"
bash "$SETUP_SCRIPT" "$output_dir" --new >/dev/null 2>&1

# Try --new again on existing dir
if bash "$SETUP_SCRIPT" "$output_dir" --new >/dev/null 2>&1; then
    fail "should have exited non-zero for existing directory"
else
    pass "exits non-zero for existing directory"
fi

teardown_test
trap - EXIT

# ─── Test 5: Resume fails if directory doesn't exist ─────────────────────────

setup_test "setup: resume fails for non-existent directory"
trap teardown_test EXIT

if bash "$SETUP_SCRIPT" "$TEST_TMPDIR/nonexistent" --resume >/dev/null 2>&1; then
    fail "should have exited non-zero for missing directory"
else
    pass "exits non-zero for missing directory"
fi

teardown_test
trap - EXIT

# ─── Test 6: Git repo is properly initialized ────────────────────────────────

setup_test "setup: git repo has initial commit with task directories"
trap teardown_test EXIT

output_dir="$TEST_TMPDIR/test-run"
bash "$SETUP_SCRIPT" "$output_dir" --new >/dev/null 2>&1

commit_msg=$(cd "$output_dir/main" && git log --oneline -1)
echo "$commit_msg" | grep -q "init: workspace bootstrap" \
    && pass "initial commit message correct" \
    || fail "unexpected commit message: $commit_msg"

teardown_test
trap - EXIT

# ─── Summary ─────────────────────────────────────────────────────────────────

echo
total=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}  $total/$total passed${NC}"
    exit 0
else
    echo -e "${RED}  $((total - FAIL))/$total passed  ($FAIL failed)${NC}"
    exit 1
fi
