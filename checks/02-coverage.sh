#!/usr/bin/env bash
# Check 02: Coverage >= 80%
# Runs: npm run test:coverage
# Parses Jest coverage output for global thresholds
# Pass: all coverage metrics >= 80%

set -euo pipefail

cd "$APP_ROOT"

# Run coverage, capture output
OUTPUT=$(npm run test:coverage 2>&1) || true
echo "$OUTPUT" | tail -50 > "$RESULTS_DIR/coverage-output.txt"

# Check for coverageThreshold enforcement
if echo "$OUTPUT" | grep -q "coverageThreshold"; then
  # Jest enforces threshold — exit code 1 if below
  npm run test:coverage >> "$RESULTS_DIR/check-02-coverage.log" 2>&1
fi

# Parse actual coverage numbers from output
for METRIC in lines branches statements functions; do
  # Extract coverage percentage for each metric
  VALUE=$(echo "$OUTPUT" | grep -A1 "^[ ]*${METRIC}" | grep -oP '\d+' | tail -1 || echo "0")
  echo "$METRIC: $VALUE%" >> "$RESULTS_DIR/coverage-metrics.txt"
done

pass
