#!/bin/bash
# run-tests.sh — Exercise ring-status.sh against mock oc responses.
#
# Usage:
#   ./test/run-tests.sh              # run all tests
#   ./test/run-tests.sh <test_name>  # run a single test (e.g. "single_cluster")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "$SCRIPT_DIR")"
RING_STATUS="${PROD_DIR}/ring-status.sh"
MOCK_OC="${SCRIPT_DIR}/mock-oc"

# Put mock-oc first on PATH so it shadows the real oc
chmod +x "$MOCK_OC"
export PATH="${SCRIPT_DIR}:${PATH}"

# mock-oc is already named correctly; create a symlink named 'oc'
ln -sf mock-oc "${SCRIPT_DIR}/oc"

trap 'rm -f "${SCRIPT_DIR}/oc"' EXIT

passed=0
failed=0
skipped=0
run_filter="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

run_test() {
  local name="$1"
  local description="$2"
  shift 2

  if [[ -n "$run_filter" && "$name" != "$run_filter" ]]; then
    skipped=$(( skipped + 1 ))
    return 0
  fi

  printf "${BOLD}TEST${RESET} %-30s %s\n" "$name" "$description"

  local output exit_code=0
  output=$("$@" 2>&1) || exit_code=$?

  echo "$output" > "${SCRIPT_DIR}/last-output-${name}.txt"
  return $exit_code
}

assert_exit() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    printf "  ${GREEN}✓${RESET} exit code %d (expected %d)\n" "$actual" "$expected"
    return 0
  else
    printf "  ${RED}✗${RESET} exit code %d (expected %d)\n" "$actual" "$expected"
    return 1
  fi
}

assert_contains() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
    return 0
  else
    printf "  ${RED}✗${RESET} %s (pattern: %s)\n" "$label" "$pattern"
    return 1
  fi
}

assert_not_contains() {
  local file="$1" pattern="$2" label="$3"
  if ! grep -qE "$pattern" "$file" 2>/dev/null; then
    printf "  ${GREEN}✓${RESET} %s\n" "$label"
    return 0
  else
    printf "  ${RED}✗${RESET} %s (unexpected pattern found: %s)\n" "$label" "$pattern"
    return 1
  fi
}

record_result() {
  if [[ $1 -eq 0 ]]; then
    passed=$(( passed + 1 ))
  else
    failed=$(( failed + 1 ))
  fi
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}━━━ ring-status.sh test suite ━━━${RESET}\n\n"

# ── 1. Version flag ─────────────────────────────────────────────────────────
test_result=0
run_test "version" "--version prints version" \
  bash "$RING_STATUS" --version || true
out="${SCRIPT_DIR}/last-output-version.txt"
assert_exit 0 0 "version" || test_result=1
assert_contains "$out" "ring-status 0\.[0-9]" "contains version string" || test_result=1
record_result $test_result

# ── 2. Help flag ────────────────────────────────────────────────────────────
test_result=0
run_test "help" "--help shows usage" \
  bash "$RING_STATUS" --help || true
out="${SCRIPT_DIR}/last-output-help.txt"
assert_contains "$out" "Usage:" "contains Usage header" || test_result=1
assert_contains "$out" "Health checks performed" "lists health checks" || test_result=1
assert_contains "$out" "Cross-cluster comparison" "documents drift detection" || test_result=1
assert_contains "$out" "yq.*v4" "documents yq version requirement" || test_result=1
record_result $test_result

# ── 3. Unknown flag errors ──────────────────────────────────────────────────
test_result=0
run_test "unknown_flag" "rejects unknown flags" \
  bash "$RING_STATUS" --bogus || true
out="${SCRIPT_DIR}/last-output-unknown_flag.txt"
assert_contains "$out" "Error.*unknown option" "prints error message" || test_result=1
record_result $test_result

# ── 4. Invalid ring value ──────────────────────────────────────────────────
test_result=0
run_test "invalid_ring" "--ring with bad value errors" \
  bash "$RING_STATUS" --ring xyz || true
out="${SCRIPT_DIR}/last-output-invalid_ring.txt"
assert_contains "$out" "Error.*--ring value must be" "prints ring validation error" || test_result=1
record_result $test_result

# ── 5. Single cluster — default context (healthy) ──────────────────────────
test_result=0
run_test "single_cluster" "single cluster default context" \
  bash "$RING_STATUS" --context kflux-fedora-01 || true
out="${SCRIPT_DIR}/last-output-single_cluster.txt"
assert_contains "$out" "CatalogSource.*READY" "CatalogSource is READY" || test_result=1
assert_contains "$out" "TektonConfig.*Ready" "TektonConfig is Ready" || test_result=1
assert_contains "$out" "Subscription.*CSV.*v1.16.0" "Subscription shows CSV" || test_result=1
assert_contains "$out" "Pod health.*8/8 healthy" "all pods healthy" || test_result=1
assert_contains "$out" "tekton-events-controller.*running" "events controller running" || test_result=1
assert_contains "$out" "PaC controller.*sha=" "PaC controller has SHA" || test_result=1
assert_contains "$out" "All 6 checks passed" "all checks pass" || test_result=1
record_result $test_result

# ── 6. Single cluster — unhealthy pods ─────────────────────────────────────
test_result=0
run_test "unhealthy_pods" "cluster with unhealthy pods" \
  bash "$RING_STATUS" --cluster kflux-rhel-p01 || true
out="${SCRIPT_DIR}/last-output-unhealthy_pods.txt"
assert_contains "$out" "Pod health.*2/8 unhealthy" "detects 2 unhealthy pods" || test_result=1
assert_contains "$out" "failed" "reports failures" || test_result=1
record_result $test_result

# ── 7. Ring 1 — all healthy ────────────────────────────────────────────────
test_result=0
run_test "ring1" "--ring 1 checks 3 clusters" \
  bash "$RING_STATUS" --ring 1 || true
out="${SCRIPT_DIR}/last-output-ring1.txt"
assert_contains "$out" "kflux-fedora-01" "checks kflux-fedora-01" || test_result=1
assert_contains "$out" "stone-prod-p01" "checks stone-prod-p01" || test_result=1
assert_contains "$out" "kflux-osp-p01" "checks kflux-osp-p01" || test_result=1
assert_contains "$out" "All checks passed across 3" "3 clusters all pass" || test_result=1
record_result $test_result

# ── 8. Ring all — includes unreachable cluster + drift ─────────────────────
test_result=0
run_test "ring_all" "--ring all exercises all 9 clusters" \
  bash "$RING_STATUS" --ring all || true
out="${SCRIPT_DIR}/last-output-ring_all.txt"
assert_contains "$out" "kflux-prd-rh02.*unreachable|Cluster unreachable" "detects unreachable cluster" || test_result=1
assert_contains "$out" "kflux-rhel-p01" "includes unhealthy cluster" || test_result=1
assert_contains "$out" "CSV Drift Detected" "detects CSV drift between rings" || test_result=1
assert_contains "$out" "Some checks failed" "reports overall failures" || test_result=1
record_result $test_result

# ── 9. Summary mode ────────────────────────────────────────────────────────
test_result=0
run_test "summary" "--ring all --summary compact table" \
  bash "$RING_STATUS" --ring all --summary || true
out="${SCRIPT_DIR}/last-output-summary.txt"
assert_contains "$out" "RING.*CLUSTER.*CATSRC.*TKCFG.*CSV" "prints table header" || test_result=1
assert_contains "$out" "kflux-fedora-01" "includes ring-1 cluster" || test_result=1
assert_contains "$out" "RDY" "shows RDY status" || test_result=1
assert_contains "$out" "ERR.*unreachable" "shows unreachable as ERR" || test_result=1
assert_contains "$out" "cluster.*checked" "shows cluster count" || test_result=1
record_result $test_result

# ── 10. Verify mode (extended checks) ─────────────────────────────────────
test_result=0
run_test "verify" "--verify runs extended checks" \
  bash "$RING_STATUS" --context kflux-fedora-01 --verify || true
out="${SCRIPT_DIR}/last-output-verify.txt"
assert_contains "$out" "Pruner CronJob.*last=" "runs pruner CronJob check" || test_result=1
assert_contains "$out" "Marketplace pods.*4/4 healthy" "runs marketplace pods check" || test_result=1
assert_contains "$out" "All 8 checks passed" "8 checks with verify" || test_result=1
record_result $test_result

# ── 11. JSON output ────────────────────────────────────────────────────────
if command -v jq &>/dev/null; then
  test_result=0
  run_test "json" "--json produces valid JSON" \
    bash "$RING_STATUS" --ring 1 --json || true
  out="${SCRIPT_DIR}/last-output-json.txt"
  # The JSON goes to stdout; the detailed output goes to stderr. Our capture gets both.
  # Extract just the JSON part (starts with [ and ends with ])
  if jq '.' < <(sed -n '/^\[/,/^\]/p' "$out") > /dev/null 2>&1; then
    printf "  ${GREEN}✓${RESET} output is valid JSON\n"
  else
    printf "  ${RED}✗${RESET} output is not valid JSON\n"
    test_result=1
  fi
  if grep -q '"status"' "$out"; then
    printf "  ${GREEN}✓${RESET} JSON contains status field\n"
  else
    printf "  ${RED}✗${RESET} JSON missing status field\n"
    test_result=1
  fi
  if grep -q '"csv"' "$out"; then
    printf "  ${GREEN}✓${RESET} JSON contains csv field\n"
  else
    printf "  ${RED}✗${RESET} JSON missing csv field\n"
    test_result=1
  fi
  record_result $test_result
else
  printf "${YELLOW}SKIP${RESET} json (jq not installed)\n\n"
  skipped=$(( skipped + 1 ))
fi

# ── 12. Invalid cluster name ──────────────────────────────────────────────
test_result=0
run_test "invalid_cluster" "--cluster with nonexistent name" \
  bash "$RING_STATUS" --cluster nonexistent-cluster || true
out="${SCRIPT_DIR}/last-output-invalid_cluster.txt"
assert_contains "$out" "Error.*not found in ring-mappings" "rejects unknown cluster" || test_result=1
assert_contains "$out" "Known clusters" "lists known clusters" || test_result=1
record_result $test_result

# ── 13. Context override with --ring ───────────────────────────────────────
test_result=0
run_test "context_override" "--context overrides per-cluster context" \
  bash "$RING_STATUS" --ring 1 --context kflux-fedora-01 || true
out="${SCRIPT_DIR}/last-output-context_override.txt"
# All 3 ring-1 clusters should be checked against the same context (kflux-fedora-01)
# so all should show v1.16.0 and all should pass
assert_contains "$out" "All checks passed across 3" "all pass with same context" || test_result=1
assert_not_contains "$out" "Drift Detected" "no drift when same context" || test_result=1
record_result $test_result

# ── 14. No-color output (pipe to file) ────────────────────────────────────
test_result=0
run_test "no_color" "colors disabled when not a tty" \
  bash "$RING_STATUS" --context kflux-fedora-01 || true
out="${SCRIPT_DIR}/last-output-no_color.txt"
# Since we're capturing output (not a tty), ANSI codes should be absent
assert_not_contains "$out" $'\033' "no ANSI escape codes in output" || test_result=1
record_result $test_result

# ── 15. Events controller not ready ───────────────────────────────────────
test_result=0
run_test "events_not_ready" "events controller reports not ready" \
  bash "$RING_STATUS" --cluster kflux-ocp-p01 || true
out="${SCRIPT_DIR}/last-output-events_not_ready.txt"
assert_contains "$out" "tekton-events-controller.*0/1 ready" "detects events controller not ready" || test_result=1
record_result $test_result

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}━━━ Results ━━━${RESET}\n"
total=$(( passed + failed ))
printf "  ${GREEN}%d passed${RESET}  ${RED}%d failed${RESET}" "$passed" "$failed"
[[ $skipped -gt 0 ]] && printf "  ${YELLOW}%d skipped${RESET}" "$skipped"
echo ""

# Cleanup test artifacts
rm -f "${SCRIPT_DIR}"/last-output-*.txt

if [[ $failed -gt 0 ]]; then
  printf "\n${RED}FAIL${RESET}\n"
  exit 1
else
  printf "\n${GREEN}ALL TESTS PASSED${RESET}\n"
  exit 0
fi
