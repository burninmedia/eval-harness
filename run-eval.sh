#!/usr/bin/env bash
# =============================================================================
# eval-harness — host launcher
# =============================================================================
# Snapshots the scaffold to /tmp, builds the harness Docker image, and runs
# the in-container entrypoint against the snapshot. The scaffold on the host
# is never mutated; the only thing written back to the host is the new
# `<scaffold>/.eval-results/<timestamp>/` directory.
#
# Usage:
#   ./run-eval.sh /path/to/scaffold
#   ./run-eval.sh .                       # current directory
#
# Requirements (host): Docker only. Bash, jq, node, npm etc. live in the image.
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log()  { echo -e "${BLUE}[LAUNCHER]${RESET} $*"; }
pass() { echo -e "${GREEN}[OK]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Validate args / host environment
# -----------------------------------------------------------------------------
APP_INPUT="${1:-.}"
if [[ ! -d "$APP_INPUT" ]]; then
  fail "Scaffold path not found: $APP_INPUT"
  exit 1
fi
APP_ROOT_HOST="$(cd "$APP_INPUT" && pwd)"

if [[ ! -f "$APP_ROOT_HOST/package.json" ]]; then
  fail "No package.json in $APP_ROOT_HOST"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  fail "docker not found on PATH — install Docker Desktop or the engine"
  exit 1
fi

# -----------------------------------------------------------------------------
# Snapshot the scaffold to /tmp (immutable from the harness's perspective)
# -----------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
WORK_DIR="/tmp/eval-harness-$TIMESTAMP"
RESULTS_HOST="$APP_ROOT_HOST/.eval-results/$TIMESTAMP"

log "Scaffold:  $APP_ROOT_HOST"
log "Snapshot:  $WORK_DIR"
log "Results:   $RESULTS_HOST"

mkdir -p "$WORK_DIR"

# rsync if available (faster, easier to exclude); cp -R as fallback.
if command -v rsync &>/dev/null; then
  rsync -a \
    --exclude='node_modules' \
    --exclude='.eval-results' \
    --exclude='.git' \
    "$APP_ROOT_HOST/" "$WORK_DIR/"
else
  cp -R "$APP_ROOT_HOST/." "$WORK_DIR/"
  rm -rf "$WORK_DIR/node_modules" "$WORK_DIR/.eval-results" "$WORK_DIR/.git"
fi

cleanup() {
  log "Cleaning up snapshot..."
  rm -rf "$WORK_DIR" || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Build the harness image (cached after first run)
# -----------------------------------------------------------------------------
log "Building harness image (eval-harness:latest)... (first run takes ~60s; cached after)"
BUILD_LOG="$(mktemp)"
if ! docker build -t eval-harness:latest "$HARNESS_DIR" >"$BUILD_LOG" 2>&1; then
  fail "Failed to build harness image — output:"
  cat "$BUILD_LOG"
  rm -f "$BUILD_LOG"
  exit 1
fi
rm -f "$BUILD_LOG"
pass "Harness image ready"

# -----------------------------------------------------------------------------
# Run the in-container entrypoint
# -----------------------------------------------------------------------------
# - Mount the docker socket so the harness can drive the host daemon
# - Mount the snapshot at the SAME path inside and outside the container so
#   any `docker run -v ...` / `docker compose` calls the harness makes resolve
#   correctly through the host daemon.
log "Running harness inside container..."

set +e
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$WORK_DIR:$WORK_DIR" \
  -e EVAL_SKIP_INSTALL="${EVAL_SKIP_INSTALL:-0}" \
  -e APP_PORT="${APP_PORT:-3000}" \
  -e APP_HOST="host.docker.internal" \
  -e HARNESS_TIMESTAMP="$TIMESTAMP" \
  eval-harness:latest "$WORK_DIR"
EVAL_EXIT=$?
set -e

# -----------------------------------------------------------------------------
# Copy results back to the host scaffold
# -----------------------------------------------------------------------------
SNAPSHOT_RESULTS="$WORK_DIR/.eval-results"
if [[ -d "$SNAPSHOT_RESULTS" ]]; then
  mkdir -p "$APP_ROOT_HOST/.eval-results"
  cp -R "$SNAPSHOT_RESULTS/." "$APP_ROOT_HOST/.eval-results/"
  pass "Results copied to $APP_ROOT_HOST/.eval-results/"
else
  warn "No results directory produced inside container"
fi

exit "$EVAL_EXIT"
