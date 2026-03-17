#!/usr/bin/env bash
# Entrypoint for swarm Docker containers
# Runs in two modes: orchestrator or worker
set -euo pipefail

# Unset CLAUDECODE to allow nested Claude sessions
unset CLAUDECODE 2>/dev/null || true

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
    echo "Usage: /entrypoint.sh orchestrator | worker <agent-id>" >&2
    exit 1
fi

# Build model flag for claude CLI (empty string if no model specified)
CLAUDE_MODEL_FLAG=""
if [[ -n "${MODEL:-}" ]]; then
    CLAUDE_MODEL_FLAG="--model $MODEL"
fi

# Max log file size in bytes (default 10MB). Truncates from the front,
# keeping the most recent output. Set MAX_LOG_SIZE=0 to disable.
MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"

# Truncate a log file if it exceeds MAX_LOG_SIZE, keeping the tail.
truncate_log() {
    local _tl_file="$1"
    [[ "$MAX_LOG_SIZE" -eq 0 ]] && return
    [[ -f "$_tl_file" ]] || return
    local _tl_size
    _tl_size=$(stat -f%z "$_tl_file" 2>/dev/null || stat -c%s "$_tl_file" 2>/dev/null || echo 0)
    if [[ "$_tl_size" -gt "$MAX_LOG_SIZE" ]]; then
        local _tl_tmp
        _tl_tmp=$(mktemp)
        echo "[log truncated — exceeded ${MAX_LOG_SIZE} bytes at $(date)]" > "$_tl_tmp"
        tail -c "$MAX_LOG_SIZE" "$_tl_file" >> "$_tl_tmp"
        mv "$_tl_tmp" "$_tl_file"
    fi
}

# Run claude with real-time log streaming.
# --output-format stream-json --include-partial-messages streams tokens as they
# arrive (no PTY needed — streaming is built into the CLI flag).
# stream_parse.py writes text chunks to log in real-time and saves the final
# result text to CLAUDE_OUTPUT_FILE for signal/rate-limit grep afterwards.
run_claude() {
    local _rc_prompt="$1"
    local _rc_log="$2"

    local _rc_prompt_file
    _rc_prompt_file=$(mktemp)
    printf '%s' "$_rc_prompt" > "$_rc_prompt_file"

    CLAUDE_OUTPUT_FILE=$(mktemp)

    claude --dangerously-skip-permissions $CLAUDE_MODEL_FLAG -p \
        --output-format stream-json --verbose --include-partial-messages \
        < "$_rc_prompt_file" 2>&1 | \
    python3 "$(dirname "$0")/stream_parse.py" "$CLAUDE_OUTPUT_FILE" "$_rc_log" || true

    rm -f "$_rc_prompt_file"

    # Cap log file size after each invocation
    truncate_log "$_rc_log"
}

# Security notice for public repos — prepended to all prompts when set
SECURITY_NOTICE=""
if [[ "${PUBLIC_REPO:-false}" == "true" ]]; then
    SECURITY_NOTICE="
## SECURITY — PUBLIC REPOSITORY

This project is pushed to a **public** GitHub repository. All commits are visible to anyone.

**You MUST NOT commit any of the following:**
- API keys, tokens, passwords, or secrets of any kind
- Private keys, certificates, or credentials
- Personally identifiable information (PII)
- Internal URLs, IP addresses, or infrastructure details
- .env files or any file containing secrets

**Use placeholder values** (e.g. \`YOUR_API_KEY_HERE\`, \`localhost\`) in code and config files.
**Add a .gitignore** that excludes .env, credentials files, and other secret-bearing paths.
If a task requires secrets, create a .env.example with placeholder keys and document the setup.

---

"
fi

# ─────────────────────────────────────────────────────────────
# ORCHESTRATOR MODE
# ─────────────────────────────────────────────────────────────

run_orchestrator() {
    local task="${TASK:-}"
    local log_file="${LOGS_DIR:-/logs}/orchestrator.log"

    if [[ -z "$task" ]]; then
        echo "ERROR: TASK env var not set" >&2
        exit 1
    fi

    echo "=== Orchestrator started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone "${UPSTREAM_DIR:-/upstream}" "${WORKSPACE_DIR:-/workspace}" -q 2>/dev/null
    cd "${WORKSPACE_DIR:-/workspace}"
    git config user.email "orchestrator@swarm"
    git config user.name "Swarm Orchestrator"

    # Prepare prompt (awk handles multiline TASK safely; sed breaks on newlines)
    local next_task_num="${NEXT_TASK_NUM:-}"
    local prompt
    prompt=$(awk -v task="$task" -v next_num="$next_task_num" '{
        if ($0 ~ /\{\{TASK\}\}/) { gsub(/\{\{TASK\}\}/, ""); print task }
        else if ($0 ~ /\{\{NEXT_TASK_NUM\}\}/) { gsub(/\{\{NEXT_TASK_NUM\}\}/, ""); print next_num }
        else { print }
    }' "${PROMPTS_DIR:-/prompts}/orchestrator.md")

    # Append shared task creation guide
    prompt="${prompt}
$(cat "${PROMPTS_DIR:-/prompts}/task-format.md")"
    prompt="${SECURITY_NOTICE}${prompt}"

    echo "Orchestrator analyzing task and creating subtasks..." >> "$log_file"

    run_claude "$prompt" "$log_file"
    rm -f "$CLAUDE_OUTPUT_FILE"

    echo "=== Orchestrator finished $(date) ===" >> "$log_file"
}

# ─────────────────────────────────────────────────────────────
# REVIEWER MODE
# ─────────────────────────────────────────────────────────────

run_reviewer() {
    local completed_task="${COMPLETED_TASK:-}"
    local review_num="${REVIEW_NUM:-0}"
    local log_file="${LOGS_DIR:-/logs}/reviewer-${review_num}.log"

    echo "=== Reviewer ${review_num} started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone "${UPSTREAM_DIR:-/upstream}" "${WORKSPACE_DIR:-/workspace}" -q 2>/dev/null
    cd "${WORKSPACE_DIR:-/workspace}"
    git config user.email "reviewer@swarm"
    git config user.name "Swarm Reviewer"

    # Prepare prompt — substitute COMPLETED_TASK and REVIEW_NUM
    local prompt
    prompt=$(sed -e "s|{{COMPLETED_TASK}}|${completed_task}|g" \
                 -e "s|{{REVIEW_NUM}}|${review_num}|g" \
                 "${PROMPTS_DIR:-/prompts}/reviewer.md")

    # Append shared task creation guide
    prompt="${prompt}
$(cat "${PROMPTS_DIR:-/prompts}/task-format.md")"
    prompt="${SECURITY_NOTICE}${prompt}"

    run_claude "$prompt" "$log_file"
    rm -f "$CLAUDE_OUTPUT_FILE"

    echo "=== Reviewer ${review_num} finished $(date) ===" >> "$log_file"
}

# ─────────────────────────────────────────────────────────────
# SPECIALIST MODE
# ─────────────────────────────────────────────────────────────

run_specialist() {
    local specialist_name="${SPECIALIST_NAME:-specialist}"
    local specialist_role="${SPECIALIST_ROLE:-}"
    local specialist_num="${SPECIALIST_NUM:-0}"
    local log_file="${LOGS_DIR:-/logs}/specialist-${specialist_name}-${specialist_num}.log"

    echo "=== Specialist ${specialist_name} (${specialist_num}) started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone "${UPSTREAM_DIR:-/upstream}" "${WORKSPACE_DIR:-/workspace}" -q 2>/dev/null
    cd "${WORKSPACE_DIR:-/workspace}"
    git config user.email "${specialist_name}@swarm"
    git config user.name "Swarm ${specialist_name}"

    # Prepare prompt — substitute SPECIALIST_NAME, SPECIALIST_ROLE, SPECIALIST_NUM
    local prompt
    prompt=$(sed -e "s|{{SPECIALIST_NAME}}|${specialist_name}|g" \
                 -e "s|{{SPECIALIST_NUM}}|${specialist_num}|g" \
                 "${PROMPTS_DIR:-/prompts}/specialist.md")
    # Inject role (may contain newlines and special chars — awk -v handles literal assignment)
    prompt=$(echo "$prompt" | awk -v role="$specialist_role" '{
        if ($0 ~ /\{\{SPECIALIST_ROLE\}\}/) {
            gsub(/\{\{SPECIALIST_ROLE\}\}/, "")
            print role
        } else {
            print
        }
    }')

    # Append shared task creation guide
    prompt="${prompt}
$(cat "${PROMPTS_DIR:-/prompts}/task-format.md")"
    prompt="${SECURITY_NOTICE}${prompt}"

    run_claude "$prompt" "$log_file"
    rm -f "$CLAUDE_OUTPUT_FILE"

    echo "=== Specialist ${specialist_name} (${specialist_num}) finished $(date) ===" >> "$log_file"
}

# ─────────────────────────────────────────────────────────────
# WORKER MODE
# ─────────────────────────────────────────────────────────────

run_worker() {
    local agent_id="${2:-}"
    local verbose="${VERBOSE:-false}"
    local max_iterations="${MAX_WORKER_ITERATIONS:-100}"

    if [[ -z "$agent_id" ]]; then
        echo "Usage: /entrypoint.sh worker <agent-id>" >&2
        exit 1
    fi

    local worker_name="worker-$agent_id"
    local log_file="${LOGS_DIR:-/logs}/${worker_name}.log"

    echo "=== Worker $agent_id started $(date) ===" > "$log_file"

    # Clone bare repo — fail fast if clone fails (prevents infinite respawn loops)
    if ! git clone "${UPSTREAM_DIR:-/upstream}" "${WORKSPACE_DIR:-/workspace}" -q 2>>"$log_file"; then
        echo "FATAL: git clone failed — exiting to prevent respawn loop" >> "$log_file"
        echo "=== Worker $agent_id CLONE_FAILED at $(date) ===" >> "$log_file"
        exit 2
    fi
    cd "${WORKSPACE_DIR:-/workspace}"
    git config user.email "${worker_name}@swarm"
    git config user.name "Swarm Worker $agent_id"

    # Prepare prompt
    local prompt
    prompt=$(sed "s|{{AGENT_ID}}|${worker_name}|g" "${PROMPTS_DIR:-/prompts}/worker.md")
    prompt="${SECURITY_NOTICE}${prompt}"

    local iteration=0
    local rate_limit_attempts=0
    local -a backoff_delays=(300 900 1800 3600 7200 14400)

    while true; do
        # Pull latest state
        git pull origin main -q 2>/dev/null || true

        # Count work available
        local pending own_active all_active
        pending=$(find tasks/pending -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        own_active=$(find tasks/active/ -maxdepth 1 -name "${worker_name}--*.md" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        all_active=$(find tasks/active -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

        # If no work for this agent — waits don't count against the iteration limit
        if [[ "$pending" -eq 0 && "$own_active" -eq 0 ]]; then
            if [[ "$all_active" -eq 0 ]]; then
                if [[ "${MULTI_ROUND:-false}" == "true" ]]; then
                    # In multi-round mode, reviewer may add tasks — sleep and wait
                    sleep 15
                    continue
                fi
                echo "Worker $agent_id: all tasks complete" >> "$log_file"
                echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
                exit 0
            else
                # Other workers still active, wait
                sleep 5
                continue
            fi
        fi

        echo -e "\n--- Worker $agent_id (pending attempt, $(date)) ---" >> "$log_file"
        echo "State: pending=$pending own_active=$own_active all_active=$all_active" >> "$log_file"

        # Run one agent session — output streams to log in real-time,
        # full text saved to CLAUDE_OUTPUT_FILE for signal/rate-limit grep.
        run_claude "$prompt" "$log_file"

        # Check for rate-limit — keep task claimed, sleep, retry (does NOT count as an iteration)
        if grep -qi "rate limit\|too many requests\|quota exceeded\|429 \|hit your limit\|resets.*UTC" "$CLAUDE_OUTPUT_FILE" 2>/dev/null; then
            local delay_idx=$(( rate_limit_attempts < ${#backoff_delays[@]} ? rate_limit_attempts : ${#backoff_delays[@]} - 1 ))
            local base_delay="${backoff_delays[$delay_idx]}"
            local jitter=$(( (RANDOM % 41) + 80 ))
            local sleep_secs=$(( base_delay * jitter / 100 ))
            rate_limit_attempts=$(( rate_limit_attempts + 1 ))
            echo "[rate-limit] attempt ${rate_limit_attempts}, sleeping ${sleep_secs}s (base=${base_delay}s, jitter=${jitter}%)" >> "$log_file"
            rm -f "$CLAUDE_OUTPUT_FILE"
            sleep "$sleep_secs"
            continue
        fi

        # Successful call — count it and reset rate-limit backoff counter
        iteration=$((iteration + 1))
        if [[ $iteration -gt $max_iterations ]]; then
            echo "Worker $agent_id: reached max iterations ($max_iterations)" >> "$log_file"
            echo "=== Worker $agent_id MAXED OUT at $(date) ===" >> "$log_file"
            rm -f "$CLAUDE_OUTPUT_FILE"
            exit 0
        fi
        rate_limit_attempts=0

        # Check completion signals
        if grep -q "ALL_DONE\|NO_TASKS\|TASK_DONE" "$CLAUDE_OUTPUT_FILE" 2>/dev/null; then
            if [[ "${MULTI_ROUND:-false}" == "true" ]]; then
                # In multi-round mode, harness kills workers — never self-exit on signals
                rm -f "$CLAUDE_OUTPUT_FILE"
                sleep 2
                continue
            fi
            echo "Worker $agent_id: signaled completion" >> "$log_file"
            echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
            rm -f "$CLAUDE_OUTPUT_FILE"
            exit 0
        fi
        rm -f "$CLAUDE_OUTPUT_FILE"

        sleep 2
    done
}

# ─────────────────────────────────────────────────────────────
# DISPATCH
# ─────────────────────────────────────────────────────────────

case "$ROLE" in
    orchestrator)
        run_orchestrator
        ;;
    worker)
        run_worker "$@"
        ;;
    reviewer)
        run_reviewer
        ;;
    specialist)
        run_specialist
        ;;
    *)
        echo "Unknown role: $ROLE (expected orchestrator, worker, reviewer, or specialist)" >&2
        exit 1
        ;;
esac
