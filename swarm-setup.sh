#!/usr/bin/env bash
# swarm-setup.sh — Initialize workspace and extract config for the agent harness.
#
# Usage:
#   bash swarm-setup.sh <output-dir> --new      # New run: init workspace
#   bash swarm-setup.sh <output-dir> --resume    # Resume: just extract config
#
# Outputs key=value pairs to stdout for the agent to capture.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-}"
MODE="${2:---new}"

if [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: bash swarm-setup.sh <output-dir> [--new|--resume]" >&2
    exit 1
fi

# Resolve to absolute path
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")" \
    || OUTPUT_DIR="$(pwd)/$(basename "$OUTPUT_DIR")"

# ── Docker image ──────────────────────────────────────────────

DOCKER_IMAGE="swarm-agent"
if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
    echo "Building Docker image '$DOCKER_IMAGE'..." >&2
    docker build -t "$DOCKER_IMAGE" "$SCRIPT_DIR" >&2
fi

# ── OAuth token ───────────────────────────────────────────────

OAUTH_TOKEN=""
if [[ "$(uname)" == "Darwin" ]]; then
    OAUTH_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null) || true
else
    # Claude Code stores credentials as .credentials.json (dot-prefixed) or credentials.json
    creds_file="$HOME/.claude/.credentials.json"
    [[ ! -f "$creds_file" ]] && creds_file="$HOME/.claude/credentials.json"
    if [[ -f "$creds_file" ]]; then
        OAUTH_TOKEN=$(python3 -c "import json; print(json.load(open('$creds_file')).get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null) || true
    fi
fi

if [[ -z "$OAUTH_TOKEN" ]]; then
    echo "ERROR: Could not extract OAuth token" >&2
    exit 1
fi

# ── Workspace init (new runs only) ────────────────────────────

REPO_DIR="$OUTPUT_DIR/repo.git"
MAIN_DIR="$OUTPUT_DIR/main"
LOGS_DIR="$OUTPUT_DIR/logs"

if [[ "$MODE" == "--new" ]]; then
    if [[ -d "$OUTPUT_DIR/main/tasks" ]]; then
        echo "ERROR: Output directory already exists: $OUTPUT_DIR (use --resume)" >&2
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

    # Init bare repo
    mkdir -p "$REPO_DIR"
    git init --bare "$REPO_DIR" -q

    # Bootstrap with task directories
    local_tmp=$(mktemp -d)
    git clone "$REPO_DIR" "$local_tmp" -q 2>/dev/null
    (
        cd "$local_tmp"
        git config user.email "swarm@local"
        git config user.name "Swarm"

        mkdir -p tasks/pending tasks/active tasks/done
        touch tasks/pending/.gitkeep tasks/active/.gitkeep tasks/done/.gitkeep

        cat > SPEC.md << 'SPECEOF'
# Project Specification

*Created by orchestrator. This is a placeholder.*
SPECEOF

        cat > PROGRESS.md << 'PROGEOF'
# Progress

**Status:** INITIALIZING

*Updated by agents as work progresses.*
PROGEOF

        git add -A
        git commit -m "init: workspace bootstrap" -q
        git push origin main -q
    )
    rm -rf "$local_tmp"

    # Clone the main view
    git clone "$REPO_DIR" "$MAIN_DIR" -q 2>/dev/null
    (
        cd "$MAIN_DIR"
        git config user.email "swarm@local"
        git config user.name "Swarm"
    )

    echo "Workspace initialized: $OUTPUT_DIR" >&2
elif [[ "$MODE" == "--resume" ]]; then
    if [[ ! -d "$OUTPUT_DIR/main/tasks" ]]; then
        echo "ERROR: Not a swarm output directory: $OUTPUT_DIR" >&2
        exit 1
    fi
    echo "Resuming from: $OUTPUT_DIR" >&2
else
    echo "ERROR: Unknown mode: $MODE (expected --new or --resume)" >&2
    exit 1
fi

# ── Output config ─────────────────────────────────────────────

cat <<EOF
SWARM_OUTPUT_DIR=$OUTPUT_DIR
SWARM_REPO_DIR=$REPO_DIR
SWARM_MAIN_DIR=$MAIN_DIR
SWARM_LOGS_DIR=$LOGS_DIR
SWARM_OAUTH_TOKEN=$OAUTH_TOKEN
SWARM_PROMPTS_DIR=$SCRIPT_DIR/prompts
EOF
