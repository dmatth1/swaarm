# Inject Subcommand Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `inject` subcommand that adds new task files to a running or paused swarm run based on freeform user guidance.

**Architecture:** `./swarm inject <output-dir> "<guidance>"` spins up a Docker container in a new "inject" role. The inject agent reads SPEC.md + existing task state, then creates new numbered task files in `tasks/pending/` picking up from the current max task number + 1. The harness calculates the next task number and passes it as `NEXT_TASK_NUM` env var so the agent doesn't have to discover it. All changes are committed to the bare repo.

**Tech Stack:** bash 5+, existing Docker/git infrastructure, new `prompts/inject.md` prompt template

---

## Chunk 1: Core implementation + tests

**Files:**
- Create: `prompts/inject.md` — inject agent prompt template
- Modify: `docker/entrypoint.sh` — add `run_inject()` function and `inject)` case
- Modify: `swarm` — add `cmd_inject()`, `docker_run_inject()`, `inject)` subcommand
- Create: `tests/test_inject.sh` — tests for cmd_inject

---

### Task 1: Add `run_inject` to entrypoint and prompt

**Files:**
- Create: `prompts/inject.md`
- Modify: `docker/entrypoint.sh`

- [ ] **Step 1: Write failing test — inject role dispatched correctly**

Create `tests/test_inject.sh`:

```bash
#!/usr/bin/env bash
# Integration tests for cmd_inject.
# Mocks docker_run_inject to write task files directly.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/helpers.sh"

# ─── Test 1: inject creates new task files with correct numbering ─────────────

setup_test "inject: creates task files starting after existing max"
trap teardown_test EXIT

init_test_workspace
push_file_to_repo "tasks/done/001-setup.md"   "# Task 001" "done 001"
push_file_to_repo "tasks/done/002-build.md"   "# Task 002" "done 002"
push_file_to_repo "tasks/pending/003-tests.md" "# Task 003" "add 003"

load_swarm

CAPTURED_NEXT_NUM=""
CAPTURED_GUIDANCE=""
ensure_docker_image() { :; }
docker_run_inject() {
    local guidance="$1"
    local next_num="$2"
    CAPTURED_GUIDANCE="$guidance"
    CAPTURED_NEXT_NUM="$next_num"
    # Simulate agent creating a task file at the correct number
    local tmp
    tmp=$(mktemp -d)
    git clone "$REPO_DIR" "$tmp" -q 2>/dev/null
    (
        cd "$tmp"
        git config user.email "test@swarm"
        git config user.name "Test"
        printf '# Task %03d: Add auth\n' "$next_num" > "tasks/pending/$(printf '%03d' "$next_num")-add-auth.md"
        git add -A
        git commit -m "inject: add auth task" -q
        git push origin main -q
    )
    rm -rf "$tmp"
}

cmd_inject "$OUTPUT_DIR" "Add OAuth authentication"

assert_eq "4" "$CAPTURED_NEXT_NUM" "next_num passed as 4 (after max 003)"
assert_eq "Add OAuth authentication" "$CAPTURED_GUIDANCE" "guidance passed through"

(cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true
assert_file_exists "$MAIN_DIR/tasks/pending/004-add-auth.md" "task 004 created in pending"

teardown_test
trap - EXIT

print_summary
```

- [ ] **Step 2: Run to verify it fails**

```bash
chmod +x tests/test_inject.sh
bash tests/test_inject.sh
```
Expected: FAIL — `cmd_inject: command not found`

- [ ] **Step 3: Create `prompts/inject.md`**

```markdown
# Swarm Inject Agent

You are an **INJECT AGENT** in a multi-agent development system. A swarm run is already in progress (or paused). Your job is to add new tasks to the queue based on new guidance from the user.

---

## New Guidance

{{GUIDANCE}}

---

## Your Environment

You are working in a git repository that already has a project in progress.

Directory structure:
- `tasks/pending/` — create new task files here
- `tasks/active/` — tasks currently being worked (do not touch)
- `tasks/done/` — completed tasks (do not touch)
- `SPEC.md` — the original project specification (read this for context)

---

## What You Must Do

### 1. Read Context

Read `SPEC.md` to understand the project, technology stack, and existing interfaces.

List the existing tasks:
```bash
ls tasks/done/ tasks/active/ tasks/pending/ 2>/dev/null
```

Read any pending task files to avoid duplicating work already queued.

### 2. Create New Task Files

Create task files in `tasks/pending/`. Start numbering at **{{NEXT_TASK_NUM}}** — do not use any lower number as those are taken.

Follow the same task file format as the original orchestrator:

```markdown
# Task NNN: Task Name

## Description
What needs to be done. Be specific.

## Produces
Implements: `InterfaceName` | None

## Consumes
InterfaceName | None

## Acceptance Criteria
- [ ] Run: `<exact command>` → Expected: `<exact output>`

## Tests
- Unit: `tests/test_foo.py::test_bar` — what this validates

## Dependencies
None | Requires task NNN
```

Rules:
- Be specific — vague tasks produce vague results
- Each task must be completable by reading SPEC.md + the task file alone
- Set dependencies only where a prior task's output is literally required on disk
- Update `PROGRESS.md` to add the new tasks to the task list

### 3. Commit and Push

```bash
git add -A
git commit -m "inject: add N new task(s) — {{GUIDANCE}}"
git push origin main
```

---

## Signal Completion

After pushing, output this exact text:

<promise>INJECTION COMPLETE</promise>
```

- [ ] **Step 4: Add `run_inject()` to `docker/entrypoint.sh`**

Read `docker/entrypoint.sh` first. Then add the following function after `run_orchestrator()` (before the `# REVIEWER MODE` section):

```bash
# ─────────────────────────────────────────────────────────────
# INJECT MODE
# ─────────────────────────────────────────────────────────────

run_inject() {
    local guidance="${GUIDANCE:-}"
    local next_task_num="${NEXT_TASK_NUM:-1}"
    local verbose="${VERBOSE:-false}"
    local log_file="${LOGS_DIR:-/logs}/inject.log"

    if [[ -z "$guidance" ]]; then
        echo "ERROR: GUIDANCE env var not set" >&2
        exit 1
    fi

    echo "=== Inject agent started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone "${UPSTREAM_DIR:-/upstream}" "${WORKSPACE_DIR:-/workspace}" -q 2>/dev/null
    cd "${WORKSPACE_DIR:-/workspace}"
    git config user.email "inject@swarm"
    git config user.name "Swarm Inject"

    # Prepare prompt — use line-conditional replacement to safely handle
    # special chars (&, \, /) in guidance (same pattern as run_orchestrator)
    local prompt
    prompt=$(awk -v guidance="$guidance" -v next_num="$next_task_num" '{
        if ($0 ~ /\{\{GUIDANCE\}\}/)      { gsub(/\{\{GUIDANCE\}\}/, "");      print guidance }
        else if ($0 ~ /\{\{NEXT_TASK_NUM\}\}/) { gsub(/\{\{NEXT_TASK_NUM\}\}/, ""); print next_num }
        else { print }
    }' "${PROMPTS_DIR:-/prompts}/inject.md")

    echo "Inject agent adding tasks for: $guidance" >> "$log_file"

    if [[ "$verbose" == "true" ]]; then
        echo "$prompt" | claude --dangerously-skip-permissions -p 2>&1 | tee -a "$log_file"
    else
        echo "$prompt" | claude --dangerously-skip-permissions -p >> "$log_file" 2>&1
    fi

    echo "=== Inject agent finished $(date) ===" >> "$log_file"
}
```

Add `inject)` to the case statement at the bottom of `docker/entrypoint.sh`:

```bash
    inject)
        run_inject
        ;;
```

And update the error message for unknown roles to include `inject`:

```bash
        echo "Unknown role: $ROLE (expected orchestrator, worker, reviewer, specialist, or inject)" >&2
```

- [ ] **Step 5: Run test to verify it still fails** (cmd_inject not yet in swarm)

```bash
bash tests/test_inject.sh
```
Expected: FAIL — `cmd_inject: command not found`

---

### Task 2: Add `cmd_inject` and `docker_run_inject` to `swarm`

**Files:**
- Modify: `swarm`

- [ ] **Step 1: Add `docker_run_inject()` to `swarm`**

Read `swarm` around line 394 (after `docker_run_orchestrator`). Add after the `docker_run_orchestrator` function:

```bash
docker_run_inject() {
    local guidance="$1"
    local next_task_num="$2"

    log "Starting inject container..."

    local container_name="swarm-${RUN_ID}-inject"
    local log_file="$LOGS_DIR/inject.log"

    local oauth_token
    oauth_token=$(get_claude_oauth_token) || true

    local extra_vol_flags=()
    for _m in "${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"}"; do extra_vol_flags+=(-v "$_m"); done

    docker run --rm \
        --name "$container_name" \
        -v "$REPO_DIR:/upstream" \
        -v "$LOGS_DIR:/logs" \
        -v "$PROMPTS_DIR:/prompts:ro" \
        "${extra_vol_flags[@]+"${extra_vol_flags[@]}"}" \
        ${oauth_token:+-e CLAUDE_CODE_OAUTH_TOKEN="$oauth_token"} \
        -e GUIDANCE="$guidance" \
        -e NEXT_TASK_NUM="$next_task_num" \
        -e VERBOSE="$VERBOSE" \
        "$DOCKER_IMAGE" \
        inject || true

    sync_main

    if grep -q "INJECTION COMPLETE" "$log_file" 2>/dev/null; then
        return 0
    else
        warn "Inject agent did not signal completion. Check: $log_file"
        return 1
    fi
}
```

- [ ] **Step 2: Add `cmd_inject()` to `swarm`**

Add after `cmd_resume()` (around line 362):

```bash
cmd_inject() {
    local output_dir="${1:-}"
    local guidance="${2:-}"

    if [[ -z "$output_dir" ]]; then
        error "Usage: swarm inject <output-dir> \"<guidance>\""
        exit 1
    fi
    if [[ ! -d "$output_dir/main/tasks" ]]; then
        error "Not a swarm output directory: $output_dir"
        exit 1
    fi
    if [[ -z "$guidance" ]]; then
        error "No guidance provided."
        error "Usage: swarm inject <output-dir> \"<guidance>\""
        exit 1
    fi

    OUTPUT_DIR="$(cd "$output_dir" && pwd)"
    REPO_DIR="$OUTPUT_DIR/repo.git"
    LOGS_DIR="$OUTPUT_DIR/logs"
    MAIN_DIR="$OUTPUT_DIR/main"
    RUN_ID="$(basename "$OUTPUT_DIR")"

    echo
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║       🐝  SWARM INJECT  🐝               ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo
    info "Output:   $OUTPUT_DIR"
    info "Guidance: $guidance"
    echo

    # Pull latest state
    (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true

    # Calculate next task number (max across all states + 1)
    local max_num=0
    local f num
    for f in "$MAIN_DIR/tasks/pending/"*.md \
              "$MAIN_DIR/tasks/active/"*.md \
              "$MAIN_DIR/tasks/done/"*.md; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" | grep -o '^[0-9]*' || echo 0)
        [[ "$num" -gt "$max_num" ]] && max_num="$num"
    done
    local next_num=$(( max_num + 1 ))

    log "Current max task number: $max_num → new tasks start at $(printf '%03d' "$next_num")"
    echo

    ensure_docker_image
    docker_run_inject "$guidance" "$next_num"

    # Count newly added tasks (tasks with number >= next_num)
    local added=0
    local f num
    for f in "$MAIN_DIR/tasks/pending/"*.md; do
        [[ -f "$f" ]] || continue
        num=$(basename "$f" | grep -o '^[0-9]*' || echo 0)
        [[ "$num" -ge "$next_num" ]] && added=$((added + 1))
    done

    echo
    success "Injection complete — $added new task(s) added to pending"
    info "Run './swarm resume $output_dir' to start workers"
    echo
}
```

- [ ] **Step 3: Add `inject)` to argument parsing in `swarm`**

Find the `case "${1:-}" in` block (around line 1030). Add before the `cleanup)` case:

```bash
    inject)
        shift
        cmd_inject "${1:-}" "${2:-}"
        exit 0
        ;;
```

- [ ] **Step 4: Run Test 1 to verify it passes**

```bash
bash tests/test_inject.sh
```
Expected: `1/1 passed`

- [ ] **Step 5: Commit**

```bash
git add prompts/inject.md docker/entrypoint.sh swarm tests/test_inject.sh
git commit -m "feat: add inject subcommand to queue new tasks mid-run"
```

---

### Task 3: Complete test suite

**Files:**
- Modify: `tests/test_inject.sh` — add Tests 2–4

- [ ] **Step 1: Add Tests 2–4 before `print_summary`**

Replace the `print_summary` at the bottom with these three tests, then add `print_summary` at the very end:

```bash
# ─── Test 2: next_num starts at 1 when no tasks exist ────────────────────────

setup_test "inject: starts numbering at 1 when no tasks exist"
trap teardown_test EXIT

init_test_workspace
load_swarm

CAPTURED_NEXT_NUM=""
docker_run_inject() {
    CAPTURED_NEXT_NUM="$2"
}
ensure_docker_image() { :; }

cmd_inject "$OUTPUT_DIR" "Add login page"

assert_eq "1" "$CAPTURED_NEXT_NUM" "next_num is 1 when no tasks exist"

teardown_test
trap - EXIT

# ─── Test 3: missing output_dir → error ──────────────────────────────────────

setup_test "inject: missing output_dir exits with error"
trap teardown_test EXIT

init_test_workspace
load_swarm

output=$(cmd_inject "" "some guidance" 2>&1) && status=0 || status=$?

[[ "$status" -ne 0 ]] \
    && pass "exits non-zero on missing output_dir" \
    || fail "should have exited non-zero"

echo "$output" | grep -q "Usage:" \
    && pass "prints Usage on missing output_dir" \
    || fail "no Usage message"

teardown_test
trap - EXIT

# ─── Test 4: missing guidance → error ────────────────────────────────────────

setup_test "inject: missing guidance exits with error"
trap teardown_test EXIT

init_test_workspace
load_swarm

output=$(cmd_inject "$OUTPUT_DIR" "" 2>&1) && status=0 || status=$?

[[ "$status" -ne 0 ]] \
    && pass "exits non-zero on missing guidance" \
    || fail "should have exited non-zero"

echo "$output" | grep -q "guidance" \
    && pass "error message mentions guidance" \
    || fail "error message missing guidance"

teardown_test
trap - EXIT

print_summary
```

- [ ] **Step 2: Run the full inject suite**

```bash
bash tests/test_inject.sh
```
Expected: `4/4 passed`

- [ ] **Step 3: Run full suite**

```bash
bash tests/run_tests.sh
```
Expected: all suites pass

- [ ] **Step 4: Commit**

```bash
git add tests/test_inject.sh
git commit -m "test: add inject subcommand tests (numbering, empty queue, validation)"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `BACKLOG.md`

- [ ] **Step 1: Update README.md**

In the Usage section, add `inject` to the subcommands block:

```bash
# Add tasks to a running or paused swarm
./swarm inject <output-dir> "<new guidance>"
```

Add a new section after "Resuming after interruption":

```markdown
## Injecting new tasks

While a swarm is paused (or after it finishes), you can add new tasks based on additional guidance:

​```bash
./swarm inject ./swarm-20240115-143022 "Also add rate limiting and an admin dashboard"
​```

The inject agent reads the existing SPEC.md and task history, then creates new numbered task files in `tasks/pending/` that pick up where the existing numbering left off. Run `./swarm resume <dir>` afterward to start workers on the new tasks.
```

- [ ] **Step 2: Update CLAUDE.md**

In the Subcommands section, add:

```bash
./swarm inject <output-dir> "<guidance>"  # add tasks to existing run
```

In the signal words table, add:

```
| `<promise>INJECTION COMPLETE</promise>` | Inject agent | New tasks created and pushed |
```

- [ ] **Step 3: Mark BACKLOG item resolved** (if inject was listed)

Remove any BACKLOG entry related to task injection if present.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md BACKLOG.md
git commit -m "docs: document inject subcommand in README and CLAUDE.md"
```
