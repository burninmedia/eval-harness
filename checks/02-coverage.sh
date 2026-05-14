#!/usr/bin/env bash
# Check 02: Coverage >= 80%
# Runs: npm run test:coverage inside the harness test image.
# Pass: Jest exits 0 (coverageThreshold in package.json enforces thresholds)

set -euo pipefail

APP_ABS="$(cd "$APP_ROOT" && pwd)"
IMG="${HARNESS_TEST_IMAGE:-eval-harness/node-test:20}"

LOG="$RESULTS_DIR/check-02-coverage.log"
: >"$LOG"

set +e
docker run --rm \
  -v "$APP_ABS:/app" \
  -w /app \
  "$IMG" \
  bash -c 'npm run test:coverage' >>"$LOG" 2>&1
EXIT=$?
set -e

grep -E '^(File|All files|[[:space:]]*[-]+[|])' "$LOG" 2>/dev/null | tail -40 >"$RESULTS_DIR/coverage-metrics.txt" || true

exit "$EXIT"
