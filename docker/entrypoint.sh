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

# ─────────────────────────────────────────────────────────────
# ORCHESTRATOR MODE
# ─────────────────────────────────────────────────────────────

run_orchestrator() {
    local task="${TASK:-}"
    local verbose="${VERBOSE:-false}"
    local log_file="/logs/orchestrator.log"

    if [[ -z "$task" ]]; then
        echo "ERROR: TASK env var not set" >&2
        exit 1
    fi

    echo "=== Orchestrator started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone /upstream /workspace -q 2>/dev/null
    cd /workspace
    git config user.email "orchestrator@swarm"
    git config user.name "Swarm Orchestrator"

    # Prepare prompt (awk handles multiline TASK safely; sed breaks on newlines)
    local prompt
    prompt=$(awk -v task="$task" '{
        if ($0 ~ /\{\{TASK\}\}/) { gsub(/\{\{TASK\}\}/, ""); print task }
        else { print }
    }' /prompts/orchestrator.md)

    echo "Orchestrator analyzing task and creating subtasks..." >> "$log_file"

    # Run Claude
    if [[ "$verbose" == "true" ]]; then
        echo "$prompt" | claude --dangerously-skip-permissions -p 2>&1 | tee -a "$log_file"
    else
        echo "$prompt" | claude --dangerously-skip-permissions -p >> "$log_file" 2>&1
    fi

    echo "=== Orchestrator finished $(date) ===" >> "$log_file"
}

# ─────────────────────────────────────────────────────────────
# REVIEWER MODE
# ─────────────────────────────────────────────────────────────

run_reviewer() {
    local completed_task="${COMPLETED_TASK:-}"
    local review_num="${REVIEW_NUM:-0}"
    local log_file="/logs/reviewer-${review_num}.log"

    echo "=== Reviewer ${review_num} started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone /upstream /workspace -q 2>/dev/null
    cd /workspace
    git config user.email "reviewer@swarm"
    git config user.name "Swarm Reviewer"

    # Prepare prompt — substitute COMPLETED_TASK and REVIEW_NUM
    local prompt
    prompt=$(sed -e "s|{{COMPLETED_TASK}}|${completed_task}|g" \
                 -e "s|{{REVIEW_NUM}}|${review_num}|g" \
                 /prompts/reviewer.md)

    echo "$prompt" | claude --dangerously-skip-permissions -p >> "$log_file" 2>&1 || true

    echo "=== Reviewer ${review_num} finished $(date) ===" >> "$log_file"
}

# ─────────────────────────────────────────────────────────────
# SPECIALIST MODE
# ─────────────────────────────────────────────────────────────

run_specialist() {
    local specialist_name="${SPECIALIST_NAME:-specialist}"
    local specialist_role="${SPECIALIST_ROLE:-}"
    local specialist_num="${SPECIALIST_NUM:-0}"
    local log_file="/logs/specialist-${specialist_name}-${specialist_num}.log"

    echo "=== Specialist ${specialist_name} (${specialist_num}) started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone /upstream /workspace -q 2>/dev/null
    cd /workspace
    git config user.email "${specialist_name}@swarm"
    git config user.name "Swarm ${specialist_name}"

    # Prepare prompt — substitute SPECIALIST_NAME, SPECIALIST_ROLE, SPECIALIST_NUM
    local prompt
    prompt=$(sed -e "s|{{SPECIALIST_NAME}}|${specialist_name}|g" \
                 -e "s|{{SPECIALIST_NUM}}|${specialist_num}|g" \
                 /prompts/specialist.md)
    # Inject role (may contain newlines and special chars — use a temp file)
    local role_escaped
    role_escaped=$(printf '%s\n' "$specialist_role" | sed 's/[[\.*^$()+?{|]/\\&/g')
    prompt=$(echo "$prompt" | awk -v role="$specialist_role" '{
        if ($0 ~ /\{\{SPECIALIST_ROLE\}\}/) {
            gsub(/\{\{SPECIALIST_ROLE\}\}/, "")
            print role
        } else {
            print
        }
    }')

    echo "$prompt" | claude --dangerously-skip-permissions -p >> "$log_file" 2>&1 || true

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

    # Clone bare repo
    git clone "${UPSTREAM_DIR:-/upstream}" "${WORKSPACE_DIR:-/workspace}" -q 2>/dev/null
    cd "${WORKSPACE_DIR:-/workspace}"
    git config user.email "${worker_name}@swarm"
    git config user.name "Swarm Worker $agent_id"

    # Prepare prompt
    local prompt
    prompt=$(sed "s|{{AGENT_ID}}|${worker_name}|g" "${PROMPTS_DIR:-/prompts}/worker.md")

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

        # Run one agent session
        local output
        if [[ "$verbose" == "true" ]]; then
            output=$(echo "$prompt" | claude --dangerously-skip-permissions -p 2>&1 | tee -a "$log_file") || true
        else
            output=$(echo "$prompt" | claude --dangerously-skip-permissions -p 2>&1) || true
            echo "$output" >> "$log_file"
        fi

        # Check for rate-limit — keep task claimed, sleep, retry (does NOT count as an iteration)
        if echo "$output" | grep -qi "rate limit\|too many requests\|quota exceeded\|429 "; then
            local delay_idx=$(( rate_limit_attempts < ${#backoff_delays[@]} ? rate_limit_attempts : ${#backoff_delays[@]} - 1 ))
            local base_delay="${backoff_delays[$delay_idx]}"
            local jitter=$(( (RANDOM % 41) + 80 ))
            local sleep_secs=$(( base_delay * jitter / 100 ))
            rate_limit_attempts=$(( rate_limit_attempts + 1 ))
            echo "[rate-limit] attempt ${rate_limit_attempts}, sleeping ${sleep_secs}s (base=${base_delay}s, jitter=${jitter}%)" >> "$log_file"
            sleep "$sleep_secs"
            continue
        fi

        # Successful call — count it and reset rate-limit backoff counter
        iteration=$((iteration + 1))
        if [[ $iteration -gt $max_iterations ]]; then
            echo "Worker $agent_id: reached max iterations ($max_iterations)" >> "$log_file"
            echo "=== Worker $agent_id MAXED OUT at $(date) ===" >> "$log_file"
            exit 0
        fi
        rate_limit_attempts=0

        # Check completion signals
        if echo "$output" | grep -q "ALL_DONE\|NO_TASKS\|WORKER.*DONE"; then
            if [[ "${MULTI_ROUND:-false}" == "true" ]]; then
                # In multi-round mode, harness kills workers — never self-exit on signals
                sleep 2
                continue
            fi
            echo "Worker $agent_id: signaled completion" >> "$log_file"
            echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
            exit 0
        fi

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
