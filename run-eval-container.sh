#!/usr/bin/env bash
# =============================================================================
# eval-harness — in-container entrypoint
# =============================================================================
# This script runs INSIDE the eval-harness Docker image. The host launcher
# (../run-eval.sh) snapshots the scaffold to /tmp and invokes this script
# against the snapshot. Talks to the host Docker daemon via /var/run/docker.sock
# (mounted by the launcher) so child containers (test image, agent's compose
# stack) run as siblings on the host.
#
# Usage (called by the host launcher, not by hand):
#   /opt/harness/run-eval-container.sh /tmp/eval-harness-<ts>
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
APP_ROOT="${1:?usage: $0 /path/to/snapshot}"
TIMESTAMP="${HARNESS_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
RESULTS_DIR="$APP_ROOT/.eval-results/$TIMESTAMP"
REPORT_JSON="$RESULTS_DIR/report.json"
REPORT_MD="$RESULTS_DIR/report.md"

export HARNESS_DIR APP_ROOT RESULTS_DIR REPORT_JSON REPORT_MD

# Helpers
log()  { echo -e "${BLUE}[HARNESS]${RESET} $*"; }
pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
info() { echo -e "${BOLD}[INFO]${RESET} $*"; }

run_check() {
  local name="$1"
  local script="$2"
  log "Running: $name"
  set +e
  bash "$script" >> "$RESULTS_DIR/check-$name.log" 2>&1
  local rc=$?
  set -e
  echo "$rc" > "$RESULTS_DIR/check-$name.exit"

  # Parse a sub-score from common summary lines, e.g.:
  #   "Conventions: 5 passed, 2 failed"
  #   "Production checks: 8 passed, 1 failed"
  #   "Contract: 15 passed, 0 failed (of 15)"
  # Falls back to 1/1 (pass) or 0/1 (fail) for binary checks like 01/02/04/07.
  local subscore="" p="" f=""
  local summary
  summary=$(grep -iE '^[A-Za-z][A-Za-z ]*:[[:space:]]*[0-9]+[[:space:]]+passed' \
              "$RESULTS_DIR/check-$name.log" 2>/dev/null | tail -1 || true)
  if [[ -n "$summary" ]]; then
    p=$(echo "$summary" | grep -oE '[0-9]+[[:space:]]+passed' | head -1 | grep -oE '[0-9]+')
    f=$(echo "$summary" | grep -oE '[0-9]+[[:space:]]+failed' | head -1 | grep -oE '[0-9]+')
  fi
  if [[ -n "$p" && -n "$f" ]]; then
    subscore="$p/$((p + f))"
  elif [[ $rc -eq 0 ]]; then
    subscore="1/1"
  else
    subscore="0/1"
  fi
  echo "$subscore" > "$RESULTS_DIR/check-$name.score"

  if [[ $rc -eq 0 ]]; then
    pass "$name passed ($subscore)"
    return 0
  else
    fail "$name failed ($subscore) — see $RESULTS_DIR/check-$name.log"
    return 1
  fi
}

main() {
  echo ""
  log "${BOLD}Agent Coding Eval Harness (containerized)${RESET}"
  log "Snapshot:  $APP_ROOT"
  log "Results:   $RESULTS_DIR"
  echo ""

  if [[ ! -f "$APP_ROOT/package.json" ]]; then
    fail "No package.json found in $APP_ROOT"
    exit 1
  fi

  mkdir -p "$RESULTS_DIR"

  echo "============================================"
  echo "  AGENT CODING EVAL — $TIMESTAMP"
  echo "============================================"
  echo ""

  # Inside the container we already have bash, jq, curl, docker CLI + compose
  # plugin, node, npm. The only thing to discover is which compose form to use
  # (the docker:24-cli base image ships v2 as a subcommand).
  if docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
  elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
  else
    fail "No docker compose binary in harness image — fix the Dockerfile"
    exit 1
  fi
  export DOCKER_COMPOSE
  log "Using compose: $DOCKER_COMPOSE"

  # Build the test image (Node 20 + native build tools). This goes through the
  # mounted docker socket, so the image lives on the host daemon and is reused
  # across runs.
  HARNESS_TEST_IMAGE="eval-harness/node-test:20"
  export HARNESS_TEST_IMAGE
  log "Building harness test image ($HARNESS_TEST_IMAGE)..."
  if docker build -q -t "$HARNESS_TEST_IMAGE" \
      -f "$HARNESS_DIR/templates/Dockerfile.test" \
      "$HARNESS_DIR/templates/" \
      >"$RESULTS_DIR/test-image-build.log" 2>&1; then
    pass "Test image ready"
  else
    fail "Failed to build $HARNESS_TEST_IMAGE — see $RESULTS_DIR/test-image-build.log"
    exit 1
  fi

  # Install scaffold deps inside the test image. Because the snapshot lives at
  # the SAME absolute path on host and in this container, the bind-mount
  # below resolves correctly when the host daemon receives it.
  if [[ "${EVAL_SKIP_INSTALL:-0}" != "1" ]]; then
    if [[ -f "$APP_ROOT/package-lock.json" ]]; then
      log "Installing app dependencies in $HARNESS_TEST_IMAGE (npm ci)..."
      INSTALL_CMD="npm ci --no-audit --no-fund"
    else
      warn "No package-lock.json — falling back to npm install"
      INSTALL_CMD="npm install --no-audit --no-fund"
    fi
    if docker run --rm -v "$APP_ROOT:/app" -w /app "$HARNESS_TEST_IMAGE" \
        bash -c "$INSTALL_CMD" \
        >"$RESULTS_DIR/install.log" 2>&1; then
      pass "Dependencies installed"
    else
      fail "Dependency install failed — see $RESULTS_DIR/install.log"
      exit 1
    fi
  else
    log "EVAL_SKIP_INSTALL=1 set — skipping dependency install"
  fi

  # Static checks of the scaffold's container contract
  log "Checking app Docker readiness..."
  if [[ -f "$APP_ROOT/Dockerfile" ]]; then
    pass "Dockerfile found"
    echo "PASS" > "$RESULTS_DIR/check-dockerfile.txt"
  else
    warn "No Dockerfile"
    echo "MISSING" > "$RESULTS_DIR/check-dockerfile.txt"
  fi
  if [[ -f "$APP_ROOT/docker-compose.yml" ]] || [[ -f "$APP_ROOT/docker-compose.yaml" ]]; then
    pass "docker-compose found"
    echo "PASS" > "$RESULTS_DIR/check-compose.txt"
  else
    warn "No docker-compose"
    echo "MISSING" > "$RESULTS_DIR/check-compose.txt"
  fi

  echo ""
  log "=== Check 1: Unit Tests ==="
  run_check "01-tests" "$HARNESS_DIR/checks/01-tests.sh" && SCORE_TESTS=1 || SCORE_TESTS=0

  echo ""
  log "=== Check 2: Coverage >= 80% ==="
  run_check "02-coverage" "$HARNESS_DIR/checks/02-coverage.sh" && SCORE_COVERAGE=1 || SCORE_COVERAGE=0

  echo ""
  log "=== Check 3: Scaffold Conventions ==="
  run_check "03-conventions" "$HARNESS_DIR/checks/03-conventions.sh" && SCORE_CONVENTIONS=1 || SCORE_CONVENTIONS=0

  echo ""
  log "=== Check 4: Security Scan ==="
  run_check "04-security" "$HARNESS_DIR/checks/04-security.sh" && SCORE_SECURITY=1 || SCORE_SECURITY=0

  echo ""
  log "=== Check 5: Production readiness (Dockerfile / compose) ==="
  run_check "05-production" "$HARNESS_DIR/checks/05-production.sh" && SCORE_PRODUCTION=1 || SCORE_PRODUCTION=0

  echo ""
  log "=== Check 6: Functional contract (Docker stack + per-endpoint assertions) ==="
  run_check "06-functional" "$HARNESS_DIR/checks/06-functional.sh" && SCORE_FUNCTIONAL=1 || SCORE_FUNCTIONAL=0

  echo ""
  log "=== Check 7: Integration tests (npm run test:integration --if-present) ==="
  run_check "07-integration" "$HARNESS_DIR/checks/07-integration.sh" && SCORE_INTEGRATION=1 || SCORE_INTEGRATION=0

  echo ""
  log "Generating report..."
  if ! bash "$HARNESS_DIR/report/generate.sh"; then
    warn "Report generation failed — raw logs are in $RESULTS_DIR"
  fi

  echo ""
  echo "============================================"
  echo "  EVAL COMPLETE"
  echo "============================================"
  echo ""
  if [[ -f "$REPORT_MD" ]]; then
    cat "$REPORT_MD"
  else
    warn "No report.md generated"
  fi
  echo ""
  log "Full results: $RESULTS_DIR"
  log "JSON report:  $REPORT_JSON"
}

main "$@"
