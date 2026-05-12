#!/usr/bin/env bash
# Check 01: Unit Tests
# Runs: npm test
# Pass: exit code 0

set -euo pipefail

cd "$APP_ROOT"
npm test --if-present
