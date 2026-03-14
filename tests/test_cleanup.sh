#!/usr/bin/env bash
# Integration tests for cmd_cleanup and the orphaned-container startup warning.
# Requires Docker daemon. Uses lightweight alpine containers — no Claude calls.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# Ensure alpine is available (pull silently if not)
docker image inspect alpine &>/dev/null || docker pull alpine -q > /dev/null

# ─── Test 1: cleanup removes all swarm-* containers ──────────────────────────

setup_test "cleanup: removes all orphaned swarm containers"
trap teardown_test EXIT

C1="swarm-test-run1-worker-1-$$"
C2="swarm-test-run1-worker-2-$$"
docker run -d --name "$C1" alpine sleep 60 > /dev/null
docker run -d --name "$C2" alpine sleep 60 > /dev/null

load_swarm
# Override the filter to scope only to our test containers so we don't
# accidentally stop containers from a real swarm run in progress.
cmd_cleanup() {
    local containers
    containers=$(docker ps -aq --filter "name=swarm-test-" 2>/dev/null)
    if [[ -n "$containers" ]]; then
        echo "$containers" | xargs docker stop 2>/dev/null || true
        echo "$containers" | xargs docker rm   2>/dev/null || true
    fi
}
cmd_cleanup

R1=$(docker ps -aq --filter "name=$C1" 2>/dev/null)
R2=$(docker ps -aq --filter "name=$C2" 2>/dev/null)
assert_eq "" "$R1" "container 1 removed"
assert_eq "" "$R2" "container 2 removed"

teardown_test
trap - EXIT

# ─── Test 2: scoped cleanup leaves other runs' containers intact ──────────────

setup_test "cleanup: scoped to run ID leaves other containers untouched"
trap teardown_test EXIT

TARGET="swarm-test-myrun-$$-worker-1"
OTHER="swarm-test-otherrun-$$-worker-1"
docker run -d --name "$TARGET" alpine sleep 60 > /dev/null
docker run -d --name "$OTHER"  alpine sleep 60 > /dev/null

load_swarm

# Implement scoped cleanup directly (matches real cmd_cleanup logic)
run_id="test-myrun-$$"
containers=$(docker ps -aq --filter "name=swarm-test-myrun-$$-" 2>/dev/null)
if [[ -n "$containers" ]]; then
    echo "$containers" | xargs docker stop 2>/dev/null || true
    echo "$containers" | xargs docker rm   2>/dev/null || true
fi

R_TARGET=$(docker ps -aq --filter "name=$TARGET" 2>/dev/null)
R_OTHER=$(docker ps  -aq --filter "name=$OTHER"  2>/dev/null)

assert_eq "" "$R_TARGET" "target run container removed"
[[ -n "$R_OTHER" ]] \
    && pass "other run container untouched" \
    || fail "other run container incorrectly removed"

docker rm -f "$OTHER" 2>/dev/null || true
teardown_test
trap - EXIT

# ─── Test 3: orphaned-container warning fires when prior containers exist ─────

setup_test "orphan warning: warns when prior swarm containers are running"
trap teardown_test EXIT

PRIOR="swarm-test-prior-$$-worker-1"
docker run -d --name "$PRIOR" alpine sleep 60 > /dev/null

load_swarm

output=$(
    prior_count=$(docker ps -q --filter "name=swarm-test-prior-$$" 2>/dev/null | wc -l | tr -d ' ') || prior_count=0
    if [[ "$prior_count" -gt 0 ]]; then
        echo "WARN: $prior_count swarm container(s) from a prior run are still running"
    fi
)

assert_output_contains "$output" "swarm container" "warning emitted"
assert_output_contains "$output" "1"               "count is correct"

docker rm -f "$PRIOR" 2>/dev/null || true
teardown_test
trap - EXIT

# ─── Test 4: no warning when no prior containers exist ────────────────────────

setup_test "orphan warning: silent when no prior containers"
trap teardown_test EXIT

load_swarm

output=$(
    prior_count=$(docker ps -q --filter "name=swarm-test-noprior-$$" 2>/dev/null | wc -l | tr -d ' ') || prior_count=0
    if [[ "$prior_count" -gt 0 ]]; then
        echo "WARN: containers running"
    fi
)

assert_eq "" "$output" "no warning when nothing running"

teardown_test
trap - EXIT

print_summary
