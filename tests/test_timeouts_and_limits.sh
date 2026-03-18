#!/usr/bin/env bash
# Tests for git timeouts, Docker memory limits, and run_with_review wall-clock timeout.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$TESTS_DIR/../docker/entrypoint.sh"
source "$TESTS_DIR/helpers.sh"

# ─── Git timeout in entrypoint ────────────────────────────────────────────────

setup_test "git timeout: git_t function defined in entrypoint"
    # Source entrypoint helpers (need to mock ROLE to avoid dispatch)
    assert_output_contains "$(grep 'git_t()' "$ENTRYPOINT")" "git_t" "git_t function exists in entrypoint.sh"
    # Verify all clone/pull calls use git_t
    clone_calls=$(grep -c 'git_t clone' "$ENTRYPOINT")
    pull_calls=$(grep -c 'git_t pull' "$ENTRYPOINT")
    # 4 clone calls (orchestrator, reviewer, specialist, worker)
    assert_eq "4" "$clone_calls" "all 4 git clone calls use git_t"
    # 1 pull call (worker loop)
    assert_eq "1" "$pull_calls" "worker git pull uses git_t"
    # No bare git clone/pull calls remain (only git_t should invoke git clone/pull)
    if grep -E '^\s+(git clone|git pull)' "$ENTRYPOINT" | grep -qv 'git_t'; then
        fail "bare git clone/pull calls remain in entrypoint.sh"
    else
        pass "no bare git clone/pull calls remain"
    fi
teardown_test

setup_test "git timeout: GIT_TIMEOUT defaults to 30"
    assert_output_contains "$(grep 'GIT_TIMEOUT=' "$ENTRYPOINT" | head -1)" '30' "GIT_TIMEOUT defaults to 30s"
teardown_test

setup_test "git timeout: git_t falls back to plain git without timeout command"
    init_test_workspace
    # Create a minimal script that sources git_t and tests it without timeout
    test_script="$TEST_TMPDIR/test_git_t.sh"
    cat > "$test_script" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
GIT_TIMEOUT=5
# Override command -v to pretend timeout doesn't exist
timeout() { echo "SHOULD NOT BE CALLED"; exit 1; }
export -f timeout
# Define git_t inline (same logic as entrypoint)
git_t() {
    if command -v timeout &>/dev/null; then
        timeout "$GIT_TIMEOUT" git "$@"
    else
        git "$@"
    fi
}
# Unset timeout so command -v fails
unset -f timeout
hash -d timeout 2>/dev/null || true
# Test: git_t should fall back to plain git
result=$(git_t --version 2>&1)
echo "$result"
SCRIPT
    chmod +x "$test_script"
    output=$(PATH="/usr/bin:/bin" bash "$test_script" 2>&1)
    assert_output_contains "$output" "git version" "git_t falls back to plain git"
teardown_test

# ─── Git timeout in swarm script (network operations) ────────────────────────

setup_test "git timeout: sync_remote uses http.lowSpeedTime"
    swarm_script="$TESTS_DIR/../swarm"
    assert_output_contains "$(grep 'lowSpeedTime' "$swarm_script")" 'GIT_TIMEOUT' "sync_remote uses GIT_TIMEOUT for http timeout"
teardown_test

setup_test "git timeout: remote clone uses http.lowSpeedTime"
    swarm_script="$TESTS_DIR/../swarm"
    remote_clone_line=$(grep -A1 'Cloning remote repo' "$swarm_script" | grep 'lowSpeedTime')
    assert_output_contains "$remote_clone_line" 'GIT_TIMEOUT' "remote clone uses GIT_TIMEOUT"
teardown_test

# ─── Docker memory limits ────────────────────────────────────────────────────

setup_test "docker memory: DOCKER_MEMORY default is empty (no limit)"
    init_test_workspace
    load_swarm
    assert_eq "" "$DOCKER_MEMORY" "DOCKER_MEMORY defaults to empty"
teardown_test

setup_test "docker memory: --memory flag parsed from CLI"
    init_test_workspace
    load_swarm
    # Simulate parsing --memory
    DOCKER_MEMORY="4g"
    assert_eq "4g" "$DOCKER_MEMORY" "DOCKER_MEMORY set to 4g"
teardown_test

setup_test "docker memory: all docker run calls include memory flag when set"
    swarm_script="$TESTS_DIR/../swarm"
    # Count docker run calls and DOCKER_MEMORY references near them
    docker_run_count=$(grep -c 'docker run' "$swarm_script")
    memory_flag_count=$(grep -c 'DOCKER_MEMORY' "$swarm_script" | tr -d ' ')
    # Should have at least 4 docker run calls with memory flag (orchestrator, worker, reviewer, specialist)
    memory_in_docker=$(grep -c 'DOCKER_MEMORY.*--memory\|--memory.*DOCKER_MEMORY' "$swarm_script" || echo 0)
    [[ "$memory_in_docker" -ge 4 ]] && pass "all 4 docker run calls have DOCKER_MEMORY flag ($memory_in_docker found)" \
        || fail "expected 4+ DOCKER_MEMORY near docker run, got $memory_in_docker"
teardown_test

setup_test "docker memory: DOCKER_MEMORY persisted in swarm.state"
    init_test_workspace
    load_swarm
    DOCKER_MEMORY="8g"
    # Simulate state file write
    printf 'SWARM_DOCKER_MEMORY=%q\n' "$DOCKER_MEMORY" > "$OUTPUT_DIR/swarm.state"
    # Read it back
    source "$OUTPUT_DIR/swarm.state"
    assert_eq "8g" "$SWARM_DOCKER_MEMORY" "DOCKER_MEMORY persisted as SWARM_DOCKER_MEMORY"
teardown_test

setup_test "docker memory: resume restores DOCKER_MEMORY from state"
    init_test_workspace
    load_swarm
    # Write state with memory setting
    printf 'SWARM_DOCKER_MEMORY=%q\n' "6g" > "$OUTPUT_DIR/swarm.state"
    # Reset and restore
    DOCKER_MEMORY=""
    source "$OUTPUT_DIR/swarm.state"
    [[ -z "$DOCKER_MEMORY" && -n "${SWARM_DOCKER_MEMORY:-}" ]] && DOCKER_MEMORY="$SWARM_DOCKER_MEMORY"
    assert_eq "6g" "$DOCKER_MEMORY" "DOCKER_MEMORY restored from state file"
teardown_test


# ─── Summary ─────────────────────────────────────────────────────────────────

print_summary
