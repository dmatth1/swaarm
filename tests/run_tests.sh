#!/usr/bin/env bash
# Run all swarm integration test suites and report results.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo
echo -e "${CYAN}${BOLD}swarm integration tests (parallel)${NC}"
echo -e "${CYAN}$(printf '─%.0s' {1..40})${NC}"

# Docker-dependent tests run sequentially to avoid container name conflicts
DOCKER_TESTS="test_cleanup test_dead_worker test_kill"

RESULTS_DIR=$(mktemp -d)
PIDS=()
SUITES=()
SEQUENTIAL_SUITES=()

# Launch non-Docker tests in parallel
for suite in "$TESTS_DIR"/test_*.sh; do
    name=$(basename "$suite" .sh | sed 's/^test_//')
    if echo "$DOCKER_TESTS" | grep -qw "test_$name"; then
        SEQUENTIAL_SUITES+=("$suite")
        continue
    fi
    SUITES+=("$name")
    bash "$suite" > "$RESULTS_DIR/$name.out" 2>&1 &
    PIDS+=($!)
done

# Wait for parallel tests and collect results
SUITE_PASS=0
SUITE_FAIL=0
FAILED_SUITES=()

for i in "${!PIDS[@]}"; do
    name="${SUITES[$i]}"
    if wait "${PIDS[$i]}" 2>/dev/null; then
        SUITE_PASS=$((SUITE_PASS + 1))
    else
        SUITE_FAIL=$((SUITE_FAIL + 1))
        FAILED_SUITES+=("$name")
    fi
done

# Print parallel test output
for name in "${SUITES[@]}"; do
    echo
    echo -e "${CYAN}[ $name ]${NC}"
    cat "$RESULTS_DIR/$name.out"
done

# Run Docker-dependent tests sequentially
for suite in "${SEQUENTIAL_SUITES[@]}"; do
    name=$(basename "$suite" .sh | sed 's/^test_//')
    SUITES+=("$name")
    echo
    echo -e "${CYAN}[ $name (sequential) ]${NC}"
    if bash "$suite" > "$RESULTS_DIR/$name.out" 2>&1; then
        SUITE_PASS=$((SUITE_PASS + 1))
    else
        SUITE_FAIL=$((SUITE_FAIL + 1))
        FAILED_SUITES+=("$name")
    fi
    cat "$RESULTS_DIR/$name.out"
done

rm -rf "$RESULTS_DIR"

echo
echo -e "${CYAN}$(printf '─%.0s' {1..40})${NC}"
total=$((SUITE_PASS + SUITE_FAIL))
if [[ "$SUITE_FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $total suite(s) passed${NC}"
else
    echo -e "${RED}${BOLD}$SUITE_FAIL/$total suite(s) failed: ${FAILED_SUITES[*]}${NC}"
    exit 1
fi
