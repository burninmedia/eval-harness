#!/usr/bin/env bash
# =============================================================================
# eval-harness — Agent Coding Eval Runner
# =============================================================================
# Usage: ./run-eval.sh /path/to/app-root
#
# Drops into any cloned app repo and runs the full eval suite:
#   1. Validates app has required Docker/K8s files
#   2. Spins up stack with docker-compose
#   3. Runs: tests, coverage, conventions, security, functional
#   4. Generates JSON + MD report
#   5. Tears down stack
#
# Requirements: Docker, docker-compose, bash 4+
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# Paths
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="${1:-.}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="$APP_ROOT/.eval-results/$TIMESTAMP"
REPORT_JSON="$RESULTS_DIR/report.json"
REPORT_MD="$RESULTS_DIR/report.md"

# Scores (updated by each check)
SCORE_TESTS=0
SCORE_COVERAGE=0
SCORE_CONVENTIONS=0
SCORE_SECURITY=0
SCORE_FUNCTIONAL=0

export HARNESS_DIR APP_ROOT RESULTS_DIR

# =============================================================================
# Helpers
# =============================================================================

log() { echo -e "${BLUE}[HARNESS]${RESET} $*"; }
pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
info() { echo -e "${BOLD}[INFO]${RESET} $*"; }

run_check() {
  local name="$1"
  local script="$2"
  log "Running: $name"
  if bash "$script" >> "$RESULTS_DIR/check-$name.log" 2>&1; then
    pass "$name passed"
    return 0
  else
    fail "$name failed — see $RESULTS_DIR/check-$name.log"
    return 1
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo ""
  log "${BOLD}Agent Coding Eval Harness${RESET}"
  log "App root: $APP_ROOT"
  log "Results:  $RESULTS_DIR"
  echo ""

  # Validate app root
  if [[ ! -f "$APP_ROOT/package.json" ]]; then
    fail "No package.json found in $APP_ROOT"
    exit 1
  fi

  # Create results dir
  mkdir -p "$RESULTS_DIR"

  # Header
  echo ""
  echo "============================================"
  echo "  AGENT CODING EVAL — $TIMESTAMP"
  echo "============================================"
  echo ""

  # Check 0: Prerequisites
  log "Checking prerequisites..."
  for cmd in docker docker-compose node npm; do
    if ! command -v $cmd &>/dev/null; then
      fail "$cmd not found — install required tools"
      exit 1
    fi
  done
  pass "All prerequisites found"

  # Check 1: App Validation (Dockerfile + docker-compose exist)
  log "Checking app Docker readiness..."
  if [[ -f "$APP_ROOT/Dockerfile" ]]; then
    pass "Dockerfile found"
    echo "PASS" > "$RESULTS_DIR/check-dockerfile.txt"
  else
    warn "No Dockerfile — one will be generated"
    echo "GENERATED" > "$RESULTS_DIR/check-dockerfile.txt"
  fi

  if [[ -f "$APP_ROOT/docker-compose.yml" ]] || [[ -f "$APP_ROOT/docker-compose.yaml" ]]; then
    pass "docker-compose found"
    echo "PASS" > "$RESULTS_DIR/check-compose.txt"
  else
    warn "No docker-compose — one will be generated"
    echo "GENERATED" > "$RESULTS_DIR/check-compose.txt"
  fi

  # Check 2: Tests
  echo ""
  log "=== Check 1: Unit Tests ==="
  run_check "01-tests" "$HARNESS_DIR/checks/01-tests.sh" && SCORE_TESTS=1 || SCORE_TESTS=0

  # Check 3: Coverage
  echo ""
  log "=== Check 2: Coverage >= 80% ==="
  run_check "02-coverage" "$HARNESS_DIR/checks/02-coverage.sh" && SCORE_COVERAGE=1 || SCORE_COVERAGE=0

  # Check 4: Conventions
  echo ""
  log "=== Check 3: Scaffold Conventions ==="
  run_check "03-conventions" "$HARNESS_DIR/checks/03-conventions.sh" && SCORE_CONVENTIONS=1 || SCORE_CONVENTIONS=0

  # Check 5: Security
  echo ""
  log "=== Check 4: Security Scan ==="
  run_check "04-security" "$HARNESS_DIR/checks/04-security.sh" && SCORE_SECURITY=1 || SCORE_SECURITY=0

  # Check 6: Functional (Docker spin-up + smoke test)
  echo ""
  log "=== Check 5: Functional (Docker stack + smoke test) ==="
  run_check "05-functional" "$HARNESS_DIR/checks/05-functional.sh" && SCORE_FUNCTIONAL=1 || SCORE_FUNCTIONAL=0

  # Generate report
  echo ""
  log "Generating report..."
  bash "$HARNESS_DIR/report/generate.sh"

  echo ""
  echo "============================================"
  echo "  EVAL COMPLETE"
  echo "============================================"
  echo ""
  cat "$REPORT_MD"
  echo ""
  log "Full results: $RESULTS_DIR"
  log "JSON report:  $REPORT_JSON"
}

main "$@"
