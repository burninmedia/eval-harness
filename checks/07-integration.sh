#!/usr/bin/env bash
# Check 07: Integration tests
# Runs: npm run test:integration --if-present inside the harness test image.
# Pass: exit code 0 (also passes silently if the script isn't defined)

set -euo pipefail

APP_ABS="$(cd "$APP_ROOT" && pwd)"
IMG="${HARNESS_TEST_IMAGE:-eval-harness/node-test:20}"

# `npm run <script> --if-present` exits 0 if the script is undefined, so this
# check is a no-op for scaffolds that don't ship integration tests yet.
docker run --rm \
  -v "$APP_ABS:/app" \
  -w /app \
  "$IMG" \
  bash -c 'npm run test:integration --if-present'
