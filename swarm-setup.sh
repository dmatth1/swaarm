#!/usr/bin/env bash
# swarm-setup.sh — Initialize workspace, configure remotes, and extract config.
#
# Usage:
#   bash swarm-setup.sh <output-dir> --new                    # New run: init workspace
#   bash swarm-setup.sh <output-dir> --resume                  # Resume: extract config
#   bash swarm-setup.sh <output-dir> --configure-remote <url>  # Set up GitHub SSH remote + hook
#   bash swarm-setup.sh <output-dir> --build-cache             # Create shared build cache dir
#   bash swarm-setup.sh <output-dir> --unstick-tasks           # Move stuck active tasks to pending
#
# Outputs key=value pairs to stdout for --new and --resume.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-}"
MODE="${2:-}"

if [[ -z "$OUTPUT_DIR" ]]; then
    echo "Usage: bash swarm-setup.sh <output-dir> <mode> [args...]" >&2
    exit 1
fi

# Resolve to absolute path
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")" \
    || OUTPUT_DIR="$(pwd)/$(basename "$OUTPUT_DIR")"

REPO_DIR="$OUTPUT_DIR/repo.git"
MAIN_DIR="$OUTPUT_DIR/main"
LOGS_DIR="$OUTPUT_DIR/logs"

# ── Ensure github.com is in known_hosts (skip if already present or in test) ──

if [[ "${SWARM_SKIP_KEYSCAN:-}" != "1" ]]; then
    if [[ ! -f "$HOME/.ssh/known_hosts" ]] || ! grep -q "github.com" "$HOME/.ssh/known_hosts" 2>/dev/null; then
        mkdir -p "$HOME/.ssh"
        ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
    fi
fi

# ── Docker image (skip if SWARM_SKIP_DOCKER=1, e.g. in tests) ──

if [[ "${SWARM_SKIP_DOCKER:-}" != "1" ]]; then
    DOCKER_IMAGE="swarm-agent"
    if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
        echo "Building Docker image '$DOCKER_IMAGE'..." >&2
        docker build -t "$DOCKER_IMAGE" "$SCRIPT_DIR" >&2
    fi
fi

# ── OAuth token (skip if SWARM_SKIP_AUTH=1, e.g. in tests) ──

OAUTH_TOKEN=""
if [[ "${SWARM_SKIP_AUTH:-}" != "1" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        OAUTH_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
            | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null) || true
    else
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
fi

# ── Mode dispatch ────────────────────────────────────────────

case "$MODE" in

--new)
    # ── Workspace init ───────────────────────────────────────
    if [[ -d "$OUTPUT_DIR/main/tasks" ]]; then
        echo "ERROR: Output directory already exists: $OUTPUT_DIR (use --resume)" >&2
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

    mkdir -p "$REPO_DIR"
    git init --bare "$REPO_DIR" -q

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

    git clone "$REPO_DIR" "$MAIN_DIR" -q 2>/dev/null
    (
        cd "$MAIN_DIR"
        git config user.email "swarm@local"
        git config user.name "Swarm"
    )

    echo "Workspace initialized: $OUTPUT_DIR" >&2

    cat <<EOF
SWARM_OUTPUT_DIR=$OUTPUT_DIR
SWARM_REPO_DIR=$REPO_DIR
SWARM_MAIN_DIR=$MAIN_DIR
SWARM_LOGS_DIR=$LOGS_DIR
SWARM_OAUTH_TOKEN=$OAUTH_TOKEN
SWARM_PROMPTS_DIR=$SCRIPT_DIR/prompts
EOF
    ;;

--resume)
    if [[ ! -d "$OUTPUT_DIR/main/tasks" ]]; then
        echo "ERROR: Not a swarm output directory: $OUTPUT_DIR" >&2
        exit 1
    fi

    echo "Resuming from: $OUTPUT_DIR" >&2

    cat <<EOF
SWARM_OUTPUT_DIR=$OUTPUT_DIR
SWARM_REPO_DIR=$REPO_DIR
SWARM_MAIN_DIR=$MAIN_DIR
SWARM_LOGS_DIR=$LOGS_DIR
SWARM_OAUTH_TOKEN=$OAUTH_TOKEN
SWARM_PROMPTS_DIR=$SCRIPT_DIR/prompts
EOF
    ;;

--configure-remote)
    REPO_URL="${3:-}"
    if [[ -z "$REPO_URL" ]]; then
        echo "Usage: bash swarm-setup.sh <output-dir> --configure-remote <github-url>" >&2
        exit 1
    fi

    # Convert HTTPS to SSH URL
    SSH_URL="$REPO_URL"
    if [[ "$REPO_URL" == https://github.com/* ]]; then
        SSH_URL="git@github.com:$(echo "$REPO_URL" | sed 's|https://github.com/||;s|\.git$||').git"
    fi

    # Add remote if not exists
    if ! (cd "$REPO_DIR" && git remote get-url github 2>/dev/null); then
        (cd "$REPO_DIR" && git remote add github "$SSH_URL")
    else
        (cd "$REPO_DIR" && git remote set-url github "$SSH_URL")
    fi

    # Kill any existing mirror loop
    pkill -f "swarm-mirror-$OUTPUT_DIR" 2>/dev/null || true

    # Start background mirror loop on the host (pushes every 30s)
    bash -c "while true; do cd \"$REPO_DIR\" && git push github --all -q 2>/dev/null; sleep 30; done" &
    MIRROR_PID=$!
    echo "$MIRROR_PID" > "$OUTPUT_DIR/mirror.pid"

    # Initial push
    (cd "$REPO_DIR" && git push github --all -q 2>&1) && echo "Remote configured, mirror loop started (PID $MIRROR_PID): $SSH_URL" >&2 \
        || echo "Remote configured but initial push failed (check SSH key): $SSH_URL" >&2
    ;;

--build-cache)
    mkdir -p "$OUTPUT_DIR/build-cache"
    sudo chown 1001:1001 "$OUTPUT_DIR/build-cache" 2>/dev/null || chmod 777 "$OUTPUT_DIR/build-cache"
    echo "Build cache ready: $OUTPUT_DIR/build-cache" >&2
    ;;

--unstick-tasks)
    (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true
    stuck=$(find "$MAIN_DIR/tasks/active" -name "*.md" ! -name ".gitkeep" 2>/dev/null)
    if [[ -z "$stuck" ]]; then
        echo "No stuck tasks" >&2
        exit 0
    fi

    tmp=$(mktemp -d)
    git clone "$REPO_DIR" "$tmp" -q 2>/dev/null
    (
        cd "$tmp"
        git config user.email "harness@swarm"
        git config user.name "Swarm Harness"
        for f in tasks/active/*.md; do
            [[ -f "$f" ]] || continue
            [[ "$(basename "$f")" == ".gitkeep" ]] && continue
            base=$(basename "$f" | sed 's/^worker-[^-]*--//')
            git mv "$f" "tasks/pending/$base"
            echo "Returned: $base" >&2
        done
        git commit -m "harness: return stuck tasks to pending" -q
        git push origin main -q
    )
    rm -rf "$tmp"
    (cd "$MAIN_DIR" && git pull origin main -q 2>/dev/null) || true
    ;;

*)
    echo "ERROR: Unknown mode: $MODE" >&2
    echo "Usage: bash swarm-setup.sh <output-dir> [--new|--resume|--configure-remote <url>|--build-cache|--unstick-tasks]" >&2
    exit 1
    ;;
esac
