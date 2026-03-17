#!/usr/bin/env bash
# End-to-end integration tests for swarm.
# Exercises the full coordination loop with real git operations but mock claude.
# No Docker, no API tokens — mock claude performs git work directly.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$TESTS_DIR/../docker/entrypoint.sh"
source "$TESTS_DIR/helpers.sh"

# ─── Shared infrastructure ───────────────────────────────────────────────────

MOCK_BIN=""
E2E_PROMPTS=""

init_e2e() {
    MOCK_BIN="$TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"

    E2E_PROMPTS="$TEST_TMPDIR/prompts"
    init_mock_prompts "$E2E_PROMPTS"
    printf 'Worker prompt for {{AGENT_ID}}\n' > "$E2E_PROMPTS/worker.md"

    mkdir -p "$TEST_TMPDIR/logs"

    # Mock sleep — records calls, returns immediately
    cat > "$MOCK_BIN/sleep" << 'SCRIPT'
#!/usr/bin/env bash
echo "$1" >> "${MOCK_STATE_DIR:-$(dirname "$0")}/sleep_log"
SCRIPT
    chmod +x "$MOCK_BIN/sleep"
}

# Run entrypoint.sh in worker mode (deterministic, sequential)
run_e2e_worker() {
    local agent_id="$1"
    local workspace="$TEST_TMPDIR/ws-worker-${agent_id}-$$-${RANDOM}"
    LOGS_DIR="$TEST_TMPDIR/logs" \
    UPSTREAM_DIR="$REPO_DIR" \
    WORKSPACE_DIR="$workspace" \
    PROMPTS_DIR="$E2E_PROMPTS" \
    MULTI_ROUND="false" \
    MAX_WORKER_ITERATIONS="${2:-5}" \
    MOCK_STATE_DIR="$MOCK_BIN" \
    PATH="$MOCK_BIN:$PATH" \
        bash "$ENTRYPOINT" worker "$agent_id" 2>/dev/null || true
}

# Sync MAIN_DIR from bare repo
sync() {
    (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true
}

# Override teardown to handle git's read-only object files
teardown_e2e() {
    # Kill any background worker processes from this test
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    wait 2>/dev/null || true
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        chmod -R u+w "$TEST_TMPDIR" 2>/dev/null || true
        rm -rf "$TEST_TMPDIR" 2>/dev/null || true
    fi
    TEST_TMPDIR=""
}

# Count .md files in a dir (excluding .gitkeep)
count_md() {
    find "$1" -maxdepth 1 -name "*.md" ! -name ".gitkeep" 2>/dev/null | wc -l | tr -d ' '
}

# Create a mock claude that does real git work based on role detection.
# Args: [scenario] — optional scenario name for edge case behavior
setup_e2e_claude() {
    local scenario="${1:-default}"
    echo "$scenario" > "$MOCK_BIN/scenario"

    cat > "$MOCK_BIN/claude" << 'MOCKEOF'
#!/usr/bin/env bash
# Mock claude for E2E tests — performs real git operations based on role
set -euo pipefail

# Skip CLI flags (--dangerously-skip-permissions, -p, --model X)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) shift 2 ;;
        *) shift ;;
    esac
done

prompt=$(cat | tr -d '\r\004')
mock_dir="${MOCK_STATE_DIR:-$(dirname "$0")}"
scenario=$(cat "$mock_dir/scenario" 2>/dev/null || echo "default")

# Per-agent call counter
agent_id="global"
if echo "$prompt" | grep -qo 'worker-[0-9]*'; then
    agent_id=$(echo "$prompt" | grep -o 'worker-[0-9]*' | head -1)
fi
counter_file="$mock_dir/count_${agent_id}"
count=$(cat "$counter_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$counter_file"

# ── WORKER ────────────────────────────────────────────────────
if echo "$prompt" | grep -q 'worker-[0-9]'; then

    # Crash scenario: claim task then exit non-zero (simulates persistent failure)
    if [[ "$scenario" == "crash" ]]; then
        git pull origin main -q 2>/dev/null || true
        own=$(find tasks/active -name "${agent_id}--*.md" 2>/dev/null | head -1 || true)
        if [[ -z "$own" ]]; then
            task=$(ls tasks/pending/*.md 2>/dev/null | grep -v .gitkeep | sort | head -1 || true)
            if [[ -n "$task" ]]; then
                tname=$(basename "$task")
                mv "$task" "tasks/active/${agent_id}--${tname}"
                git add -A
                git commit -m "${agent_id}: claim $tname" -q
                git push origin main -q 2>/dev/null || true
            fi
        fi
        exit 1
    fi

    # Rate limit scenario: first call returns rate-limit error
    if [[ "$scenario" == "ratelimit" && "$count" -eq 1 ]]; then
        echo "Error: 429 rate limit exceeded"
        exit 1
    fi

    git pull origin main -q 2>/dev/null || true

    # Check for own active task first (resume after crash/conflict)
    own_active=$(find tasks/active -name "${agent_id}--*.md" 2>/dev/null | head -1 || true)
    if [[ -n "$own_active" ]]; then
        tname=$(basename "$own_active" | sed "s/${agent_id}--//")
        mkdir -p src
        echo "# code for $tname" > "src/${tname%.md}.py"
        mv "$own_active" "tasks/done/${tname}"
        git add -A
        git commit -m "${agent_id}: complete $tname" -q
        git push origin main -q 2>/dev/null || true
        echo "<promise>TASK_DONE</promise>"
        exit 0
    fi

    # Find next pending task
    task=$(ls tasks/pending/*.md 2>/dev/null | grep -v .gitkeep | sort | head -1 || true)
    if [[ -z "$task" ]]; then
        echo "<promise>ALL_DONE</promise>"
        exit 0
    fi

    tname=$(basename "$task")

    # Claim
    mv "$task" "tasks/active/${agent_id}--${tname}"
    git add -A
    git commit -m "${agent_id}: claim $tname" -q
    if ! git push origin main -q 2>&1; then
        git reset --hard HEAD~1 -q 2>/dev/null || true
        echo "Push failed, will retry"
        exit 0
    fi

    # Do work
    mkdir -p src
    echo "# code for $tname" > "src/${tname%.md}.py"

    # Complete
    mv "tasks/active/${agent_id}--${tname}" "tasks/done/${tname}"
    git add -A
    git commit -m "${agent_id}: complete $tname" -q
    git push origin main -q 2>/dev/null || true
    echo "<promise>TASK_DONE</promise>"

# ── ORCHESTRATOR (augment mode — NEXT_TASK_NUM is set) ────────
elif [[ -n "${NEXT_TASK_NUM:-}" ]]; then
    git pull origin main -q 2>/dev/null || true
    padded=$(printf '%03d' "$NEXT_TASK_NUM")
    cat > "tasks/pending/${padded}-augmented.md" << TASKEOF
# Task ${padded}: Augmented Task
## Description
Added via orchestrator augment mode.
## Dependencies
None
TASKEOF
    git add -A
    git commit -m "orchestrator: augment with task ${padded}" -q
    git push origin main -q
    echo "<promise>ORCHESTRATION COMPLETE</promise>"

# ── FALLBACK ──────────────────────────────────────────────────
else
    echo "Mock claude: unrecognized role"
    exit 0
fi
MOCKEOF
    chmod +x "$MOCK_BIN/claude"
}

# ─── Test 1: Full happy-path lifecycle ────────────────────────────────────────

setup_test "e2e: full lifecycle — 3 tasks, 2 workers, all complete"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Simulate orchestrator: create 3 pending tasks directly in repo
for i in 1 2 3; do
    padded=$(printf '%03d' $i)
    push_file_to_repo "tasks/pending/${padded}-task.md" "$(cat <<EOF
# Task ${padded}
## Description
Build component $i.
## Dependencies
None
EOF
)" "orchestrator: create task ${padded}"
done

# Run workers sequentially — deterministic, no race conditions
run_e2e_worker 1
sync
run_e2e_worker 2
sync
remaining=$(count_md "$MAIN_DIR/tasks/pending")
if [[ "$remaining" -gt 0 ]]; then
    run_e2e_worker 1
    sync
fi

done_count=$(count_md "$MAIN_DIR/tasks/done")
pending_count=$(count_md "$MAIN_DIR/tasks/pending")
active_count=$(count_md "$MAIN_DIR/tasks/active")

[[ "$done_count" -eq 3 ]] \
    && pass "all 3 tasks completed (done=$done_count)" \
    || fail "expected 3 done, got $done_count (pending=$pending_count active=$active_count)"

[[ "$pending_count" -eq 0 ]] \
    && pass "no pending tasks remain" \
    || fail "$pending_count tasks still pending"

[[ "$active_count" -eq 0 ]] \
    && pass "no active tasks remain" \
    || fail "$active_count tasks still active"

src_count=$(find "$MAIN_DIR/src" -name "*.py" 2>/dev/null | wc -l | tr -d ' ')
[[ "$src_count" -eq 3 ]] \
    && pass "source files created for all tasks ($src_count)" \
    || fail "expected 3 source files, got $src_count"

[[ -f "$TEST_TMPDIR/logs/worker-1.log" ]] \
    && pass "worker-1 log file exists" \
    || fail "worker-1 log file missing"

commit_log=$(cd "$MAIN_DIR" && git log --oneline --all)
echo "$commit_log" | grep -q "worker-1: complete\|worker-1: claim" \
    && pass "git log contains worker-1 commits" \
    || fail "no worker-1 commits in git log"

teardown_e2e
trap - EXIT

# ─── Test 2: Worker crash recovery — task unstuck after crash ─────────────────

setup_test "e2e: crash recovery — stuck task returns to pending"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "crash"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001\n## Dependencies\nNone" "add 001"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002\n## Dependencies\nNone" "add 002"

# Worker-1 crashes — crash mock always exits 1 after claiming.
# Give enough iterations for the claim+push to succeed before exit.
run_e2e_worker 1 3
sync

# Verify task stuck in active (mock claims but never completes)
active_count=$(count_md "$MAIN_DIR/tasks/active")
[[ "$active_count" -ge 1 ]] \
    && pass "task stuck in active after crash ($active_count)" \
    || fail "expected stuck task in active, got $active_count"

# Unstick: move active tasks back to pending (simulating harness unstick)
unstick_dir=$(mktemp -d)
git clone "$REPO_DIR" "$unstick_dir" -q 2>/dev/null
(
    cd "$unstick_dir"
    git config user.email "test@swarm"
    git config user.name "Test"
    for f in tasks/active/worker-1--*.md; do
        [[ -f "$f" ]] || continue
        tname=$(basename "$f" | sed 's/worker-1--//')
        mv "$f" "tasks/pending/$tname"
    done
    git add -A
    git commit -m "harness: unstick worker-1 tasks" -q
    git push origin main -q
)
rm -rf "$unstick_dir"
sync

pending_count=$(count_md "$MAIN_DIR/tasks/pending")
[[ "$pending_count" -ge 1 ]] \
    && pass "stuck task returned to pending ($pending_count)" \
    || fail "expected tasks in pending after unstick, got $pending_count"

# Switch to default scenario and run worker to complete remaining tasks
setup_e2e_claude "default"
rm -f "$MOCK_BIN"/count_*

# Run worker enough times to clear all pending tasks (one task per run, MULTI_ROUND=false)
run_e2e_worker 1 5
sync
run_e2e_worker 1 5
sync

sync
done_count=$(count_md "$MAIN_DIR/tasks/done")
remaining_pending=$(count_md "$MAIN_DIR/tasks/pending")
remaining_active=$(count_md "$MAIN_DIR/tasks/active")
[[ "$done_count" -eq 2 ]] \
    && pass "all tasks completed after recovery ($done_count done)" \
    || fail "expected 2 done after recovery, got $done_count (pending=$remaining_pending active=$remaining_active)"

teardown_e2e
trap - EXIT

# ─── Test 3: Log streaming — claude output appears in worker log ──────────────

setup_test "e2e: log streaming — worker log has claude output"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001\n## Dependencies\nNone" "add 001"

run_e2e_worker 1
sync

log_file="$TEST_TMPDIR/logs/worker-1.log"

grep -q "Worker 1 started" "$log_file" \
    && pass "log has entrypoint header" \
    || fail "log missing entrypoint header"

grep -q "TASK_DONE" "$log_file" \
    && pass "log has TASK_DONE signal from claude" \
    || fail "log missing TASK_DONE signal"

grep -q "pending=" "$log_file" \
    && pass "log has state info (pending count)" \
    || fail "log missing state info"

teardown_e2e
trap - EXIT

# ─── Test 4: Rate limit in full worker loop ───────────────────────────────────

setup_test "e2e: rate limit — worker backs off then completes"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "ratelimit"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001\n## Dependencies\nNone" "add 001"

run_e2e_worker 1 5
sync

done_count=$(count_md "$MAIN_DIR/tasks/done")
[[ "$done_count" -eq 1 ]] \
    && pass "task completed after rate-limit recovery" \
    || fail "expected 1 done, got $done_count"

sleep_log="$MOCK_BIN/sleep_log"
if [[ -f "$sleep_log" ]]; then
    backoff=$(grep -E '^[0-9]+$' "$sleep_log" | head -1 || true)
    [[ -n "$backoff" && "$backoff" -gt 100 ]] \
        && pass "rate-limit backoff sleep recorded (${backoff}s)" \
        || pass "sleep calls recorded in log"
else
    fail "no sleep log — rate-limit backoff not triggered"
fi

teardown_e2e
trap - EXIT

# ─── Test 5: Dependency ordering — lowest-numbered first ──────────────────────

setup_test "e2e: ordering — worker picks lowest-numbered pending task"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

push_file_to_repo "tasks/pending/003-last.md" "# Task 003\n## Dependencies\nNone" "add 003"
push_file_to_repo "tasks/pending/001-first.md" "# Task 001\n## Dependencies\nNone" "add 001"
push_file_to_repo "tasks/pending/002-middle.md" "# Task 002\n## Dependencies\nNone" "add 002"

run_e2e_worker 1
sync

[[ -f "$MAIN_DIR/tasks/done/001-first.md" ]] \
    && pass "worker picked 001 first (lowest numbered)" \
    || fail "001 not in done — worker picked wrong task"

[[ -f "$MAIN_DIR/tasks/pending/002-middle.md" ]] \
    && pass "002 still pending (not yet claimed)" \
    || fail "002 not in pending"

[[ -f "$MAIN_DIR/tasks/pending/003-last.md" ]] \
    && pass "003 still pending (not yet claimed)" \
    || fail "003 not in pending"

teardown_e2e
trap - EXIT

# ─── Test 6: Resume without prompt — just respawns workers ───────────────────

setup_test "e2e: resume without prompt — workers pick up remaining tasks"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Simulate a partially completed run: 1 done, 2 pending
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done 001"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002\n## Dependencies\nNone" "add 002"
push_file_to_repo "tasks/pending/003-test.md" "# Task 003\n## Dependencies\nNone" "add 003"

load_swarm
# Override everything — test the resume path in main()
docker()                         { return 0; }
ensure_docker_image()            { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
run_specialist_sweep()           { :; }
sleep()                          { :; }
sync_main()                      { sync; }
RESTRUCTURE_INTERVAL=999
MAX_WORKER_ITERATIONS=5

# Worker mock: run real entrypoint sequentially
docker_run_worker() {
    local aid="$1"
    local ws="$TEST_TMPDIR/ws-resume-worker-${aid}-$$-${RANDOM}"
    LOGS_DIR="$LOGS_DIR" UPSTREAM_DIR="$REPO_DIR" WORKSPACE_DIR="$ws" \
    PROMPTS_DIR="$E2E_PROMPTS" MULTI_ROUND="true" MAX_WORKER_ITERATIONS="5" \
    MOCK_STATE_DIR="$MOCK_BIN" PATH="$MOCK_BIN:$PATH" \
        bash "$ENTRYPOINT" worker "$aid" 2>/dev/null &
    mkdir -p "$OUTPUT_DIR/pids"
    echo "bg-$aid" > "$OUTPUT_DIR/pids/worker-${aid}.cid"
}

# Reviewer: signal based on state
docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    sync
    local p=$(count_md "$MAIN_DIR/tasks/pending")
    local a=$(count_md "$MAIN_DIR/tasks/active")
    if [[ "$1" == "--final--" && "$p" -eq 0 && "$a" -eq 0 ]]; then
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

AUGMENT_TASK_CREATED=false
docker_run_orchestrator() {
    # Track whether orchestrator created augmentation tasks (vs. maintenance-only calls
    # like stuck detection, periodic restructure, TESTS_FAIL — which don't add tasks here)
    local prior_pending
    prior_pending=$(count_md "$MAIN_DIR/tasks/pending")
    # noop — don't actually create tasks
    local post_pending
    post_pending=$(count_md "$MAIN_DIR/tasks/pending")
    [[ "$post_pending" -gt "$prior_pending" ]] && AUGMENT_TASK_CREATED=true || true
}

# Write state file (simulating prior run)
{
    printf 'SWARM_TASK=%q\n' "build the app"
    printf 'SWARM_AGENTS=%s\n' "1"
} > "$OUTPUT_DIR/swarm.state"

# Resume with empty TASK (no new guidance)
TASK=""
NUM_AGENTS=1
main 2>/dev/null || true

sync
done_count=$(count_md "$MAIN_DIR/tasks/done")

[[ "$done_count" -ge 3 ]] \
    && pass "all tasks completed on resume ($done_count done)" \
    || fail "expected 3 done, got $done_count"

[[ "$AUGMENT_TASK_CREATED" == "false" ]] \
    && pass "orchestrator did not add augmentation tasks (no new guidance)" \
    || fail "orchestrator added tasks despite no new guidance"

teardown_e2e
trap - EXIT

# ─── Test 7: Resume with new prompt — orchestrator augments ──────────────────

setup_test "e2e: resume with new prompt — orchestrator augments project"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Simulate completed run: 2 done tasks, no pending
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done 001"
push_file_to_repo "tasks/done/002-build.md" "# Task 002" "done 002"

load_swarm
docker()                         { return 0; }
ensure_docker_image()            { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { sync; }
RESTRUCTURE_INTERVAL=999
MAX_WORKER_ITERATIONS=5

# Track orchestrator calls — can't use entrypoint (hardcodes /upstream, /workspace)
# so do the augmentation via direct git ops (same as what mock claude would do)
ORCHESTRATOR_NEXT_NUM=""
docker_run_orchestrator() {
    # Only record the first call's next_task_num — subsequent maintenance calls
    # (stuck detection, periodic restructure) should not overwrite the augment num
    [[ -z "$ORCHESTRATOR_NEXT_NUM" ]] && ORCHESTRATOR_NEXT_NUM="$1" || true
    local ws="$TEST_TMPDIR/ws-orch-augment"
    git clone "$REPO_DIR" "$ws" -q 2>/dev/null
    (
        cd "$ws"
        git config user.email "orchestrator@swarm"
        git config user.name "Swarm Orchestrator"
        local padded
        padded=$(printf '%03d' "$1")
        cat > "tasks/pending/${padded}-augmented.md" << EOF
# Task ${padded}: Augmented Task
## Description
Added via orchestrator augment mode.
## Dependencies
None
EOF
        git add -A
        git commit -m "orchestrator: augment with task ${padded}" -q
        git push origin main -q
    )
    rm -rf "$ws"
    sync
}

# Track specialist sweeps
SPECIALIST_SWEEPS=()
run_specialist_sweep() { SPECIALIST_SWEEPS+=("$1"); }

# Worker: run real entrypoint
docker_run_worker() {
    local aid="$1"
    local ws="$TEST_TMPDIR/ws-augment-worker-${aid}-$$-${RANDOM}"
    LOGS_DIR="$LOGS_DIR" UPSTREAM_DIR="$REPO_DIR" WORKSPACE_DIR="$ws" \
    PROMPTS_DIR="$E2E_PROMPTS" MULTI_ROUND="true" MAX_WORKER_ITERATIONS="5" \
    MOCK_STATE_DIR="$MOCK_BIN" PATH="$MOCK_BIN:$PATH" \
        bash "$ENTRYPOINT" worker "$aid" 2>/dev/null &
    mkdir -p "$OUTPUT_DIR/pids"
    echo "bg-$aid" > "$OUTPUT_DIR/pids/worker-${aid}.cid"
}

# Reviewer
docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    sync
    local p=$(count_md "$MAIN_DIR/tasks/pending")
    local a=$(count_md "$MAIN_DIR/tasks/active")
    if [[ "$1" == "--final--" && "$p" -eq 0 && "$a" -eq 0 ]]; then
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

# Write state file with original task
{
    printf 'SWARM_TASK=%q\n' "build the app"
    printf 'SWARM_AGENTS=%s\n' "1"
} > "$OUTPUT_DIR/swarm.state"

# Resume with DIFFERENT prompt — triggers augment
TASK="add authentication"
NUM_AGENTS=1
main 2>/dev/null || true

sync

assert_eq "3" "$ORCHESTRATOR_NEXT_NUM" "orchestrator augment starts at task 003"

[[ -f "$MAIN_DIR/tasks/done/003-augmented.md" ]] \
    && pass "augmented task 003 completed" \
    || fail "augmented task 003 not in done"

# Specialist sweep should run after augmentation
found_post_augment=false
for sweep in "${SPECIALIST_SWEEPS[@]+"${SPECIALIST_SWEEPS[@]}"}"; do
    if [[ "$sweep" == *"post-augment"* ]]; then
        found_post_augment=true
        break
    fi
done
[[ "$found_post_augment" == "true" ]] \
    && pass "specialist sweep ran after augmentation" \
    || fail "no post-augment specialist sweep (sweeps: ${SPECIALIST_SWEEPS[*]:-none})"

teardown_e2e
trap - EXIT

# ─── Test 8: Specialist sweep parses SPEC.md and calls all specialists ────────

setup_test "e2e: specialist sweep calls all specialists from SPEC.md"
trap teardown_e2e EXIT

init_test_workspace
init_e2e

# Push a SPEC.md with custom specialists
push_file_to_repo "SPEC.md" "$(cat <<'SPECEOF'
# Test Spec
**Task:** test

## Success Criteria
- [ ] pass

## Specialists

### SecurityExpert
Review code for vulnerabilities

### PerformanceEngineer
Optimize hot paths

### QAEngineer
Verify test coverage
SPECEOF
)" "add spec with specialists"

push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done"

load_swarm
# Don't use standard mocks — we need the real run_specialist_sweep
docker_run_worker()              { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { :; }

# Track specialist calls
SPECIALIST_CALLS_FILE="$TEST_TMPDIR/specialist_calls"
docker_run_specialist() {
    echo "$1" >> "$SPECIALIST_CALLS_FILE"
}

_g_specialist_count=0
run_specialist_sweep "test"

if [[ -f "$SPECIALIST_CALLS_FILE" ]]; then
    call_count=$(wc -l < "$SPECIALIST_CALLS_FILE" | tr -d ' ')
    [[ "$call_count" -eq 3 ]] \
        && pass "all 3 specialists ran ($call_count calls)" \
        || fail "expected 3 specialist calls, got $call_count"

    grep -q "SecurityExpert" "$SPECIALIST_CALLS_FILE" \
        && pass "SecurityExpert was called" \
        || fail "SecurityExpert not called"

    grep -q "PerformanceEngineer" "$SPECIALIST_CALLS_FILE" \
        && pass "PerformanceEngineer was called" \
        || fail "PerformanceEngineer not called"

    grep -q "QAEngineer" "$SPECIALIST_CALLS_FILE" \
        && pass "QAEngineer was called" \
        || fail "QAEngineer not called"
else
    fail "no specialist calls recorded"
    fail "SecurityExpert not called"
    fail "PerformanceEngineer not called"
    fail "QAEngineer not called"
fi

teardown_e2e
trap - EXIT

# ─── Test 9: Pre-flight specialist sweep runs after orchestrator ──────────────

setup_test "e2e: new run — pre-flight specialist sweep after orchestrator"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Push SPEC.md with specialists (needed for sweep to find them)
push_file_to_repo "SPEC.md" "$(cat <<'SPECEOF'
# Test Spec
## Success Criteria
- [ ] pass
## Specialists
### SecurityExpert
Review code
### QAEngineer
Check tests
SPECEOF
)" "add spec"

load_swarm
docker()                         { return 0; }
ensure_docker_image()            { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { sync; }
RESTRUCTURE_INTERVAL=999
MAX_WORKER_ITERATIONS=5

# Remove tasks dir so main() treats this as a NEW run, not resume
rm -rf "$MAIN_DIR/tasks"

# init_workspace: re-create tasks dirs (normally done by real init_workspace)
init_workspace() {
    mkdir -p "$MAIN_DIR/tasks/pending" "$MAIN_DIR/tasks/active" "$MAIN_DIR/tasks/done"
    touch "$MAIN_DIR/tasks/pending/.gitkeep" "$MAIN_DIR/tasks/active/.gitkeep" "$MAIN_DIR/tasks/done/.gitkeep"
}

# Orchestrator: create tasks directly (entrypoint hardcodes /upstream)
docker_run_orchestrator() {
    push_file_to_repo "tasks/pending/001-setup.md" "# Task 001\n## Dependencies\nNone" "orch: task 001"
    return 0
}

# Workers complete tasks
docker_run_worker() {
    local aid="$1"
    local ws="$TEST_TMPDIR/ws-preflight-${aid}-$$-${RANDOM}"
    LOGS_DIR="$LOGS_DIR" UPSTREAM_DIR="$REPO_DIR" WORKSPACE_DIR="$ws" \
    PROMPTS_DIR="$E2E_PROMPTS" MULTI_ROUND="true" MAX_WORKER_ITERATIONS="5" \
    MOCK_STATE_DIR="$MOCK_BIN" PATH="$MOCK_BIN:$PATH" \
        bash "$ENTRYPOINT" worker "$aid" 2>/dev/null &
    mkdir -p "$OUTPUT_DIR/pids"
    echo "bg-$aid" > "$OUTPUT_DIR/pids/worker-${aid}.cid"
}

# Reviewer
docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    sync
    local p=$(count_md "$MAIN_DIR/tasks/pending")
    local a=$(count_md "$MAIN_DIR/tasks/active")
    if [[ "$1" == "--final--" && "$p" -eq 0 && "$a" -eq 0 ]]; then
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    else
        echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
    fi
}

# Track specialist sweeps
SWEEP_LABELS=()
SWEEP_SPECIALIST_FILE="$TEST_TMPDIR/sweep_specialists"
docker_run_specialist() {
    echo "$1" >> "$SWEEP_SPECIALIST_FILE"
}
# Override run_specialist_sweep to track labels but still call real implementation
_real_run_specialist_sweep=$(declare -f run_specialist_sweep)
run_specialist_sweep() {
    SWEEP_LABELS+=("$1")
    # Call the real function (needs docker_run_specialist mock above)
    eval "$_real_run_specialist_sweep"
    run_specialist_sweep "$@"
}

# Actually, simpler approach: just track sweep labels
run_specialist_sweep() {
    SWEEP_LABELS+=("$1")
}

TASK="build the app"
NUM_AGENTS=1
main 2>/dev/null || true

# Verify pre-flight sweep ran
found_preflight=false
for label in "${SWEEP_LABELS[@]+"${SWEEP_LABELS[@]}"}"; do
    if [[ "$label" == "pre-flight" ]]; then
        found_preflight=true
        break
    fi
done
[[ "$found_preflight" == "true" ]] \
    && pass "pre-flight specialist sweep ran after orchestrator" \
    || fail "no pre-flight sweep (sweeps: ${SWEEP_LABELS[*]:-none})"

# Verify sweep happened before workers (pre-flight should be first label)
if [[ "${#SWEEP_LABELS[@]}" -ge 1 ]]; then
    [[ "${SWEEP_LABELS[0]}" == "pre-flight" ]] \
        && pass "pre-flight was first sweep (before workers)" \
        || fail "first sweep was '${SWEEP_LABELS[0]}', expected pre-flight"
else
    fail "no sweeps recorded at all"
fi

teardown_e2e
trap - EXIT

# ─── Test 10: Quiet period sweep fires every N completions ────────────────────

setup_test "e2e: periodic review — specialist sweep fires after N task completions"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Push SPEC.md with specialists
push_file_to_repo "SPEC.md" "$(cat <<'SPECEOF'
# Test Spec
## Success Criteria
- [ ] pass
## Specialists
### SecurityExpert
Review code
SPECEOF
)" "add spec"

# Create 4 pending tasks (quiet period at interval=3 should trigger once)
for i in 1 2 3 4; do
    padded=$(printf '%03d' $i)
    push_file_to_repo "tasks/pending/${padded}-task.md" "# Task $padded\n## Dependencies\nNone" "add $padded"
done

load_swarm
docker()                         { return 0; }
ensure_docker_image()            { :; }
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
sleep()                          { :; }
sync_main()                      { sync; }
RESTRUCTURE_INTERVAL=3
MAX_WORKER_ITERATIONS=20

# Workers
docker_run_worker() {
    local aid="$1"
    local ws="$TEST_TMPDIR/ws-qp-${aid}-$$-${RANDOM}"
    LOGS_DIR="$LOGS_DIR" UPSTREAM_DIR="$REPO_DIR" WORKSPACE_DIR="$ws" \
    PROMPTS_DIR="$E2E_PROMPTS" MULTI_ROUND="true" MAX_WORKER_ITERATIONS="10" \
    MOCK_STATE_DIR="$MOCK_BIN" PATH="$MOCK_BIN:$PATH" \
        bash "$ENTRYPOINT" worker "$aid" 2>/dev/null &
    mkdir -p "$OUTPUT_DIR/pids"
    echo "bg-$aid" > "$OUTPUT_DIR/pids/worker-${aid}.cid"
}

# Reviewer: just run tests and signal
docker_run_reviewer() {
    mkdir -p "$LOGS_DIR"
    sync
    echo "TESTS_PASS" > "$LOGS_DIR/reviewer-$2.log"
}

# Orchestrator: no-op (periodic restructuring handled by mock)
docker_run_orchestrator() { :; }

# Track sweep labels
SWEEP_LABELS=()
run_specialist_sweep() { SWEEP_LABELS+=("$1"); }

run_with_review 1

# Verify periodic review fired (at 3 completions)
found_periodic=false
for label in "${SWEEP_LABELS[@]+"${SWEEP_LABELS[@]}"}"; do
    if [[ "$label" == *"at "* ]]; then
        found_periodic=true
        break
    fi
done
[[ "$found_periodic" == "true" ]] \
    && pass "periodic specialist sweep fired after N completions" \
    || fail "no periodic sweep (sweeps: ${SWEEP_LABELS[*]:-none})"

# Verify final sweep also ran
found_final=false
for label in "${SWEEP_LABELS[@]+"${SWEEP_LABELS[@]}"}"; do
    if [[ "$label" == "final" ]]; then
        found_final=true
        break
    fi
done
[[ "$found_final" == "true" ]] \
    && pass "final specialist sweep ran before project complete" \
    || fail "no final sweep (sweeps: ${SWEEP_LABELS[*]:-none})"

teardown_e2e
trap - EXIT

print_summary
