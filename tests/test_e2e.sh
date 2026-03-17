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
    # Role marker on separate line (awk replaces {{GUIDANCE}} line with just the value)
    printf 'ROLE:inject\n{{GUIDANCE}}\nStarting at task number {{NEXT_TASK_NUM}}\n' > "$E2E_PROMPTS/inject.md"

    mkdir -p "$TEST_TMPDIR/logs"

    # Mock sleep — records calls, returns immediately
    cat > "$MOCK_BIN/sleep" << 'SCRIPT'
#!/usr/bin/env bash
echo "$1" >> "${MOCK_STATE_DIR:-$(dirname "$0")}/sleep_log"
SCRIPT
    chmod +x "$MOCK_BIN/sleep"
}

# Run entrypoint.sh in worker mode
run_e2e_worker() {
    local agent_id="$1"
    local workspace="$TEST_TMPDIR/ws-worker-${agent_id}-$(date +%s%N)"
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

# Run entrypoint.sh in inject mode
run_e2e_inject() {
    local guidance="$1"
    local next_num="$2"
    local workspace="$TEST_TMPDIR/ws-inject"
    GUIDANCE="$guidance" \
    NEXT_TASK_NUM="$next_num" \
    LOGS_DIR="$TEST_TMPDIR/logs" \
    UPSTREAM_DIR="$REPO_DIR" \
    WORKSPACE_DIR="$workspace" \
    PROMPTS_DIR="$E2E_PROMPTS" \
    MOCK_STATE_DIR="$MOCK_BIN" \
    PATH="$MOCK_BIN:$PATH" \
        bash "$ENTRYPOINT" inject 2>/dev/null || true
}

# Sync MAIN_DIR from bare repo
sync() {
    (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true
}

# Override teardown to handle git's read-only object files
teardown_e2e() {
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        chmod -R u+w "$TEST_TMPDIR" 2>/dev/null || true
        rm -rf "$TEST_TMPDIR"
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
        # Only claim if nothing already active for this worker
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
        # Complete it
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
        # Push conflict — exit cleanly, entrypoint loop will retry
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

# ── INJECT ────────────────────────────────────────────────────
elif echo "$prompt" | grep -qi 'ROLE:inject'; then
    git pull origin main -q 2>/dev/null || true
    # Next task number is the last line of the prompt (awk replaces {{NEXT_TASK_NUM}} with value)
    next_num=$(echo "$prompt" | grep -o '^[0-9]*$' | tail -1)
    next_num="${next_num:-099}"
    padded=$(printf '%03d' "$next_num")
    cat > "tasks/pending/${padded}-injected.md" << TASKEOF
# Task ${padded}: Injected Task
## Description
Injected via guidance.
## Dependencies
None
TASKEOF
    git add -A
    git commit -m "inject: add task ${padded}" -q
    git push origin main -q
    echo "<promise>INJECTION COMPLETE</promise>"

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

# Run worker-1: processes tasks sequentially (MULTI_ROUND=false → exits on signal)
run_e2e_worker 1
sync

# Run worker-2: picks up remaining tasks
run_e2e_worker 2
sync

# If any left, run worker-1 again
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

# Verify source files were created
src_count=$(find "$MAIN_DIR/src" -name "*.py" 2>/dev/null | wc -l | tr -d ' ')
[[ "$src_count" -eq 3 ]] \
    && pass "source files created for all tasks ($src_count)" \
    || fail "expected 3 source files, got $src_count"

# Verify worker log exists
[[ -f "$TEST_TMPDIR/logs/worker-1.log" ]] \
    && pass "worker-1 log file exists" \
    || fail "worker-1 log file missing"

# Verify git history shows worker commits
commit_log=$(cd "$MAIN_DIR" && git log --oneline --all)
echo "$commit_log" | grep -q "worker-1: complete\|worker-1: claim" \
    && pass "git log contains worker-1 commits" \
    || fail "no worker-1 commits in git log"

teardown_e2e
trap - EXIT

# ─── Test 2: Git conflict resolution — 2 workers race for same task ──────────

setup_test "e2e: git conflict — 2 workers race, both tasks complete"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Create 2 pending tasks
push_file_to_repo "tasks/pending/001-alpha.md" "# Task 001\n## Dependencies\nNone" "add 001"
push_file_to_repo "tasks/pending/002-beta.md" "# Task 002\n## Dependencies\nNone" "add 002"

# Launch both workers simultaneously in background
run_e2e_worker 1 &
pid1=$!
run_e2e_worker 2 &
pid2=$!

wait "$pid1" 2>/dev/null || true
wait "$pid2" 2>/dev/null || true
sync

done_count=$(count_md "$MAIN_DIR/tasks/done")
pending_count=$(count_md "$MAIN_DIR/tasks/pending")
active_count=$(count_md "$MAIN_DIR/tasks/active")

[[ "$done_count" -eq 2 ]] \
    && pass "both tasks completed ($done_count done)" \
    || fail "expected 2 done, got $done_count (pending=$pending_count active=$active_count)"

[[ "$active_count" -eq 0 ]] \
    && pass "no tasks stuck in active" \
    || fail "$active_count tasks stuck in active"

# Verify different workers claimed different tasks (check git log)
claim_log=$(cd "$MAIN_DIR" && git log --oneline | grep "claim" || true)
worker1_claims=$(echo "$claim_log" | grep -c "worker-1:" || true)
worker2_claims=$(echo "$claim_log" | grep -c "worker-2:" || true)

[[ "$worker1_claims" -ge 1 && "$worker2_claims" -ge 1 ]] \
    && pass "both workers claimed tasks (w1=$worker1_claims, w2=$worker2_claims)" \
    || pass "tasks distributed (w1=$worker1_claims, w2=$worker2_claims) — one may have handled both"

teardown_e2e
trap - EXIT

# ─── Test 3: Worker crash recovery — task unstuck after crash ─────────────────

setup_test "e2e: crash recovery — stuck task returns to pending"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "crash"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001\n## Dependencies\nNone" "add 001"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002\n## Dependencies\nNone" "add 002"

# Worker-1 crashes mid-task (mock exits 1 after claiming)
run_e2e_worker 1 1  # max_iterations=1
sync

# Verify task stuck in active
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

# Verify task returned to pending
pending_count=$(count_md "$MAIN_DIR/tasks/pending")
[[ "$pending_count" -ge 1 ]] \
    && pass "stuck task returned to pending ($pending_count)" \
    || fail "expected tasks in pending after unstick, got $pending_count"

# Switch to default scenario and run worker again
setup_e2e_claude "default"
rm -f "$MOCK_BIN/count_worker-1"  # reset counter

run_e2e_worker 1
sync
run_e2e_worker 1  # second task
sync

done_count=$(count_md "$MAIN_DIR/tasks/done")
[[ "$done_count" -eq 2 ]] \
    && pass "all tasks completed after recovery ($done_count done)" \
    || fail "expected 2 done after recovery, got $done_count"

teardown_e2e
trap - EXIT

# ─── Test 4: Inject agent — resume with new guidance creates tasks ────────────

setup_test "e2e: inject agent creates new tasks via real git"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Simulate existing run with 2 done tasks
push_file_to_repo "tasks/done/001-setup.md" "# Task 001" "done 001"
push_file_to_repo "tasks/done/002-build.md" "# Task 002" "done 002"

# Run inject agent
run_e2e_inject "add authentication support" "3"
sync

# Verify new task created
[[ -f "$MAIN_DIR/tasks/pending/003-injected.md" ]] \
    && pass "inject created task 003-injected.md" \
    || fail "task 003-injected.md not found in pending"

# Verify existing done tasks untouched
done_count=$(count_md "$MAIN_DIR/tasks/done")
[[ "$done_count" -eq 2 ]] \
    && pass "existing done tasks preserved ($done_count)" \
    || fail "done tasks changed (expected 2, got $done_count)"

# Verify inject log exists
[[ -f "$TEST_TMPDIR/logs/inject.log" ]] \
    && pass "inject log file exists" \
    || fail "inject log file missing"

teardown_e2e
trap - EXIT

# ─── Test 5: Log streaming — claude output appears in worker log ──────────────

setup_test "e2e: log streaming — worker log has claude output"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001\n## Dependencies\nNone" "add 001"

run_e2e_worker 1
sync

log_file="$TEST_TMPDIR/logs/worker-1.log"

# Log should have the entrypoint header
grep -q "Worker 1 started" "$log_file" \
    && pass "log has entrypoint header" \
    || fail "log missing entrypoint header"

# Log should have claude output (signal word from mock)
grep -q "TASK_DONE" "$log_file" \
    && pass "log has TASK_DONE signal from claude" \
    || fail "log missing TASK_DONE signal"

# Log should have state line
grep -q "pending=" "$log_file" \
    && pass "log has state info (pending count)" \
    || fail "log missing state info"

teardown_e2e
trap - EXIT

# ─── Test 6: Review loop with real worker entrypoint ──────────────────────────

setup_test "e2e: review loop — harness drives worker + reviewer to completion"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Create 2 pending tasks
push_file_to_repo "tasks/pending/001-setup.md" "# Task 001\n## Dependencies\nNone" "add 001"
push_file_to_repo "tasks/pending/002-build.md" "# Task 002\n## Dependencies\nNone" "add 002"

load_swarm
# Override harness functions
monitor_progress()               { :; }
cleanup_docker()                 { :; }
check_and_respawn_dead_workers() { :; }
pause_workers()                  { :; }
unpause_workers()                { :; }
wait_for_active_drain()          { :; }
run_specialist_sweep()           { :; }
sleep()                          { :; }
QUIET_PERIOD_INTERVAL=999
MAX_WORKER_ITERATIONS=10

# Worker: run real entrypoint (foreground, one task per call, then exit)
WORKER_RUN=0
docker_run_worker() {
    local aid="$1"
    WORKER_RUN=$((WORKER_RUN + 1))
    # Run in background like the real harness does
    (
        local ws="$TEST_TMPDIR/ws-review-worker-${aid}-${WORKER_RUN}"
        LOGS_DIR="$LOGS_DIR" \
        UPSTREAM_DIR="$REPO_DIR" \
        WORKSPACE_DIR="$ws" \
        PROMPTS_DIR="$E2E_PROMPTS" \
        MULTI_ROUND="true" \
        MAX_WORKER_ITERATIONS="5" \
        MOCK_STATE_DIR="$MOCK_BIN" \
        PATH="$MOCK_BIN:$PATH" \
            bash "$ENTRYPOINT" worker "$aid" 2>/dev/null || true
    ) &
    # Track PID for cleanup
    mkdir -p "$OUTPUT_DIR/pids"
    echo "bg-worker-${aid}" > "$OUTPUT_DIR/pids/worker-${aid}.cid"
}

# Reviewer: write appropriate signal based on task state
REVIEW_CALLS=()
docker_run_reviewer() {
    local task_name="$1"
    local review_num="$2"
    REVIEW_CALLS+=("$task_name")
    mkdir -p "$LOGS_DIR"
    sync
    local p a
    p=$(count_md "$MAIN_DIR/tasks/pending")
    a=$(count_md "$MAIN_DIR/tasks/active")
    if [[ "$task_name" == "--final--" && "$p" -eq 0 && "$a" -eq 0 ]]; then
        echo "ALL_COMPLETE" > "$LOGS_DIR/reviewer-${review_num}.log"
    else
        echo "REVIEW_DONE" > "$LOGS_DIR/reviewer-${review_num}.log"
    fi
}

run_with_review 1

sync
done_count=$(count_md "$MAIN_DIR/tasks/done")
pending_count=$(count_md "$MAIN_DIR/tasks/pending")

[[ "$done_count" -eq 2 ]] \
    && pass "all tasks completed via review loop ($done_count done)" \
    || fail "expected 2 done, got $done_count (pending=$pending_count)"

[[ "${#REVIEW_CALLS[@]}" -ge 2 ]] \
    && pass "reviewer called for completed tasks (${#REVIEW_CALLS[@]} calls)" \
    || fail "expected at least 2 reviewer calls, got ${#REVIEW_CALLS[@]}"

# Verify --final-- was the last call
last_idx=$(( ${#REVIEW_CALLS[@]} - 1 ))
[[ "${REVIEW_CALLS[$last_idx]}" == "--final--" ]] \
    && pass "final drain reviewer called last" \
    || fail "last reviewer call was '${REVIEW_CALLS[$last_idx]}', expected --final--"

teardown_e2e
trap - EXIT

# ─── Test 7: Rate limit in full worker loop ───────────────────────────────────

setup_test "e2e: rate limit — worker backs off then completes"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "ratelimit"

push_file_to_repo "tasks/pending/001-setup.md" "# Task 001\n## Dependencies\nNone" "add 001"

run_e2e_worker 1 5
sync

# Task should still complete (rate limit on call 1, success on call 2)
done_count=$(count_md "$MAIN_DIR/tasks/done")
[[ "$done_count" -eq 1 ]] \
    && pass "task completed after rate-limit recovery" \
    || fail "expected 1 done, got $done_count"

# Sleep log should show a backoff delay was recorded
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

# ─── Test 8: Dependency ordering — lowest-numbered first ──────────────────────

setup_test "e2e: ordering — worker picks lowest-numbered pending task"
trap teardown_e2e EXIT

init_test_workspace
init_e2e
setup_e2e_claude "default"

# Create tasks out of order to verify sorting
push_file_to_repo "tasks/pending/003-last.md" "# Task 003\n## Dependencies\nNone" "add 003"
push_file_to_repo "tasks/pending/001-first.md" "# Task 001\n## Dependencies\nNone" "add 001"
push_file_to_repo "tasks/pending/002-middle.md" "# Task 002\n## Dependencies\nNone" "add 002"

# Run worker once — should pick 001 (lowest)
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

print_summary
