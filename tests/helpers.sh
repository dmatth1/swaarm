#!/usr/bin/env bash
# Shared test helpers for swarm integration tests
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWARM_SCRIPT="$TESTS_DIR/../swarm"

# Counters (accumulated across the calling test file)
PASS=0
FAIL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─── Lifecycle ───────────────────────────────────────────────

TEST_TMPDIR=""

setup_test() {
    local name="$1"
    TEST_TMPDIR=$(mktemp -d)
    echo -e "${YELLOW}▶ $name${NC}"
}

teardown_test() {
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    # Remove any test containers we may have started
    docker ps -aq --filter "name=swarm-test-" 2>/dev/null \
        | xargs -r docker rm -f 2>/dev/null || true
    TEST_TMPDIR=""
}

# ─── Assertions ──────────────────────────────────────────────

pass() { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-values equal}"
    if [[ "$expected" == "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg  (expected='$expected'  actual='$actual')"
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-file exists: $(basename "$1")}"
    [[ -f "$path" ]] && pass "$msg" || fail "$msg  (not found: $path)"
}

assert_file_not_exists() {
    local path="$1" msg="${2:-file absent: $(basename "$1")}"
    [[ ! -f "$path" ]] && pass "$msg" || fail "$msg  (unexpectedly found: $path)"
}

assert_output_contains() {
    local output="$1" pattern="$2" msg="${3:-output contains: $pattern}"
    echo "$output" | grep -q "$pattern" && pass "$msg" || fail "$msg  (pattern not found)"
}

# ─── Git workspace ───────────────────────────────────────────

# Creates a minimal swarm output directory with a proper bare git repo.
# After calling, these globals are set: OUTPUT_DIR, REPO_DIR, MAIN_DIR, LOGS_DIR
init_test_workspace() {
    OUTPUT_DIR="$TEST_TMPDIR/output"
    REPO_DIR="$OUTPUT_DIR/repo.git"
    MAIN_DIR="$OUTPUT_DIR/main"
    LOGS_DIR="$OUTPUT_DIR/logs"

    mkdir -p "$REPO_DIR" "$LOGS_DIR" "$OUTPUT_DIR/pids"
    git init --bare "$REPO_DIR" -q

    local bootstrap
    bootstrap=$(mktemp -d)
    git clone "$REPO_DIR" "$bootstrap" -q 2>/dev/null
    (
        cd "$bootstrap"
        git config user.email "test@swarm"
        git config user.name "Test"
        mkdir -p tasks/pending tasks/active tasks/done
        touch tasks/pending/.gitkeep tasks/active/.gitkeep tasks/done/.gitkeep
        printf '# Test Spec\n**Task:** test\n## Success Criteria\n- [ ] pass\n' > SPEC.md
        git add -A
        git commit -m "init" -q
        git push origin main -q
    )
    rm -rf "$bootstrap"

    git clone "$REPO_DIR" "$MAIN_DIR" -q 2>/dev/null
    (
        cd "$MAIN_DIR"
        git config user.email "test@swarm"
        git config user.name "Test"
    )
}

# Commit a file to the bare repo and pull it into MAIN_DIR.
# Usage: push_file_to_repo <relative-path> <content> [commit-msg]
push_file_to_repo() {
    local path="$1" content="$2" msg="${3:-add $1}"
    local tmp
    tmp=$(mktemp -d)
    git clone "$REPO_DIR" "$tmp" -q 2>/dev/null
    (
        cd "$tmp"
        git config user.email "test@swarm"
        git config user.name "Test"
        mkdir -p "$(dirname "$path")"
        printf '%s' "$content" > "$path"
        git add -A
        git commit -m "$msg" -q
        git push origin main -q
    )
    rm -rf "$tmp"
    (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true
}

# ─── Script loading ──────────────────────────────────────────

# Source the swarm script so its functions are available.
# The BASH_SOURCE guard prevents arg-parsing / main from running.
# Call after init_test_workspace so globals (OUTPUT_DIR etc.) are set.
load_swarm() {
    # Save workspace vars: source resets them to script defaults
    local _output="${OUTPUT_DIR:-}"
    local _repo="${REPO_DIR:-}"
    local _main="${MAIN_DIR:-}"
    local _logs="${LOGS_DIR:-}"

    # shellcheck source=../swarm
    source "$SWARM_SCRIPT"

    # Restore workspace and configure for test environment
    OUTPUT_DIR="$_output"
    REPO_DIR="$_repo"
    MAIN_DIR="$_main"
    LOGS_DIR="$_logs"
    VERBOSE=false
    MAX_WORKER_ITERATIONS=100
    DOCKER_IMAGE="swarm-agent"
    RUN_ID="test-$$"
    SCRIPT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
    PROMPTS_DIR="$SCRIPT_DIR/prompts"
    TASK="test task"
    NUM_AGENTS=1
}

# ─── Summary ─────────────────────────────────────────────────

print_summary() {
    local total=$((PASS + FAIL))
    echo
    if [[ "$FAIL" -eq 0 ]]; then
        echo -e "${GREEN}  $total/$total passed${NC}"
        return 0
    else
        echo -e "${RED}  $((total - FAIL))/$total passed  ($FAIL failed)${NC}"
        return 1
    fi
}
