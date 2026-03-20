FROM node:20-bookworm

# System tools needed by workers
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    bash \
    python3 \
    python3-pip \
    python3-venv \
    golang-go \
    build-essential \
    curl \
    sudo \
    ccache \
    && rm -rf /var/lib/apt/lists/*

# ccache config: store cache at /build-cache (mounted from host), auto-use for cmake
ENV CCACHE_DIR=/build-cache
ENV CMAKE_C_COMPILER_LAUNCHER=ccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=ccache

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Non-root user required: --dangerously-skip-permissions is blocked for root
RUN useradd -m -s /bin/bash swarm && mkdir /workspace && chown swarm:swarm /workspace \
    && echo "swarm ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/swarm

# Entrypoint and stream parser
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/stream_parse.py /stream_parse.py
RUN chmod +x /entrypoint.sh

USER swarm
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
