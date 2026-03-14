#!/usr/bin/env bash
# Integration tests for check_and_respawn_dead_workers()
# No real Claude calls — uses a nonexistent container name to simulate a dead container.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ─── Test 1: dead container with active task → task returned to pending ───────

setup_test "dead worker: unsticks active task when container is gone"
trap teardown_test EXIT

init_test_workspace

# Simulate worker-1 having claimed a task
push_file_to_repo \
    "tasks/active/worker-1--001-setup.md" \
    "# Task 001\n## Produces: setup/" \
    "worker-1: claim 001"

# Fake .cid pointing to a non-existent container (docker inspect will fail → "gone")
echo "swarm-test-nonexistent-$$" > "$OUTPUT_DIR/pids/worker-1.cid"

load_swarm

# Mock docker_run_worker so we record respawn calls without launching anything
RESPAWNED=()
docker_run_worker() { RESPAWNED+=("worker-$1"); mkdir -p "$OUTPUT_DIR/pids"; echo "swarm-test-mock-$1" > "$OUTPUT_DIR/pids/worker-$1.cid"; }

check_and_respawn_dead_workers 1

# Pull changes into MAIN_DIR
(cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true

assert_file_exists "$MAIN_DIR/tasks/pending/001-setup.md"           "task returned to pending"
assert_file_not_exists "$MAIN_DIR/tasks/active/worker-1--001-setup.md" "task removed from active"
# cid file is recreated by mock docker_run_worker — check it has the new name
new_cid=$(cat "$OUTPUT_DIR/pids/worker-1.cid" 2>/dev/null || echo "")
assert_eq "swarm-test-mock-1" "$new_cid" "cid updated to new container name"
assert_eq "1" "${#RESPAWNED[@]}"         "worker was respawned"
assert_eq "worker-1" "${RESPAWNED[0]}"   "correct worker id"

teardown_test
trap - EXIT

# ─── Test 2: dead container, no stuck tasks → no respawn ──────────────────────

setup_test "dead worker: no respawn when container exited cleanly (no active tasks)"
trap teardown_test EXIT

init_test_workspace

# Container record exists but container is gone — and no active tasks
echo "swarm-test-nonexistent-$$" > "$OUTPUT_DIR/pids/worker-1.cid"

load_swarm

RESPAWNED=()
docker_run_worker() { RESPAWNED+=("$1"); }

check_and_respawn_dead_workers 1

assert_eq "0" "${#RESPAWNED[@]}" "no respawn when nothing stuck"
assert_file_not_exists "$OUTPUT_DIR/pids/worker-1.cid" "stale cid cleaned up"

teardown_test
trap - EXIT

# ─── Test 3: live container → no action taken ─────────────────────────────────

setup_test "dead worker: live container is left alone"
trap teardown_test EXIT

init_test_workspace

# Start a real lightweight container that stays alive
CONTAINER="swarm-test-live-$$"
docker run -d --name "$CONTAINER" alpine sleep 30 > /dev/null
echo "$CONTAINER" > "$OUTPUT_DIR/pids/worker-1.cid"

push_file_to_repo \
    "tasks/active/worker-1--002-build.md" \
    "# Task 002" \
    "worker-1: claim 002"

load_swarm

RESPAWNED=()
docker_run_worker() { RESPAWNED+=("$1"); }

check_and_respawn_dead_workers 1

# Task must still be active — worker is alive
assert_file_exists "$MAIN_DIR/tasks/active/worker-1--002-build.md" "active task untouched"
assert_eq "0" "${#RESPAWNED[@]}" "live worker not respawned"

docker rm -f "$CONTAINER" 2>/dev/null || true
teardown_test
trap - EXIT

print_summary
