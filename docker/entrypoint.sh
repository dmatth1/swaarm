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

    # Prepare prompt
    local prompt
    prompt=$(sed "s|{{TASK}}|$task|g" /prompts/orchestrator.md)

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
    local log_file="/logs/${worker_name}.log"

    echo "=== Worker $agent_id started $(date) ===" > "$log_file"

    # Clone bare repo
    git clone /upstream /workspace -q 2>/dev/null
    cd /workspace
    git config user.email "${worker_name}@swarm"
    git config user.name "Swarm Worker $agent_id"

    # Prepare prompt
    local prompt
    prompt=$(sed "s|{{AGENT_ID}}|${worker_name}|g" /prompts/worker.md)

    local iteration=0

    while [[ $iteration -lt $max_iterations ]]; do
        iteration=$((iteration + 1))

        # Pull latest state
        git pull origin main -q 2>/dev/null || true

        # Count work available
        local pending own_active all_active
        pending=$(find tasks/pending -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        own_active=$(find tasks/active/ -maxdepth 1 -name "${worker_name}--*.md" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        all_active=$(find tasks/active -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

        # If no work for this agent
        if [[ "$pending" -eq 0 && "$own_active" -eq 0 ]]; then
            if [[ "$all_active" -eq 0 ]]; then
                echo "Worker $agent_id: all tasks complete" >> "$log_file"
                echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
                exit 0
            else
                # Other workers still active, wait
                sleep 5
                continue
            fi
        fi

        echo -e "\n--- Worker $agent_id Iteration $iteration ($(date)) ---" >> "$log_file"
        echo "State: pending=$pending own_active=$own_active all_active=$all_active" >> "$log_file"

        # Run one agent session
        local output
        if [[ "$verbose" == "true" ]]; then
            output=$(echo "$prompt" | claude --dangerously-skip-permissions -p 2>&1 | tee -a "$log_file") || true
        else
            output=$(echo "$prompt" | claude --dangerously-skip-permissions -p 2>&1) || true
            echo "$output" >> "$log_file"
        fi

        # Check completion signals
        if echo "$output" | grep -q "ALL_DONE\|NO_TASKS\|WORKER.*DONE"; then
            echo "Worker $agent_id: signaled completion" >> "$log_file"
            echo "=== Worker $agent_id DONE at $(date) ===" >> "$log_file"
            exit 0
        fi

        sleep 2
    done

    echo "Worker $agent_id: reached max iterations ($max_iterations)" >> "$log_file"
    echo "=== Worker $agent_id MAXED OUT at $(date) ===" >> "$log_file"
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
    *)
        echo "Unknown role: $ROLE (expected orchestrator, worker, or reviewer)" >&2
        exit 1
        ;;
esac
