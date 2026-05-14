#!/usr/bin/env bash
# Check 01: Unit Tests
# Runs: npm test inside the harness test image (Node 20 + build tools).
# Pass: exit code 0

set -euo pipefail

APP_ABS="$(cd "$APP_ROOT" && pwd)"
IMG="${HARNESS_TEST_IMAGE:-eval-harness/node-test:20}"

docker run --rm \
  -v "$APP_ABS:/app" \
  -w /app \
  "$IMG" \
  bash -c 'npm test --if-present'
