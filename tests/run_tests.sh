#!/usr/bin/env bash
# Run all swarm integration test suites and report results.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SUITE_PASS=0
SUITE_FAIL=0
FAILED_SUITES=()

echo
echo -e "${CYAN}${BOLD}swarm integration tests${NC}"
echo -e "${CYAN}$(printf '─%.0s' {1..40})${NC}"

run_suite() {
    local suite="$1"
    local name
    name=$(basename "$suite" .sh | sed 's/^test_//')
    echo
    echo -e "${CYAN}[ $name ]${NC}"
    if bash "$suite"; then
        SUITE_PASS=$((SUITE_PASS + 1))
    else
        SUITE_FAIL=$((SUITE_FAIL + 1))
        FAILED_SUITES+=("$name")
    fi
}

for suite in "$TESTS_DIR"/test_*.sh; do
    run_suite "$suite"
done

echo
echo -e "${CYAN}$(printf '─%.0s' {1..40})${NC}"
total=$((SUITE_PASS + SUITE_FAIL))
if [[ "$SUITE_FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $total suite(s) passed${NC}"
else
    echo -e "${RED}${BOLD}$SUITE_FAIL/$total suite(s) failed: ${FAILED_SUITES[*]}${NC}"
    exit 1
fi
