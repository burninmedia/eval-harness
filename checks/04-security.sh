#!/usr/bin/env bash
# Check 04: Security Scan
# Runs: npm audit (human + JSON), reports critical/high counts
# Pass: 0 critical vulnerabilities (high is a warning, non-failing)

set -euo pipefail

cd "$APP_ROOT"
AUDIT_LOG="$RESULTS_DIR/npm-audit.txt"
AUDIT_JSON="$RESULTS_DIR/npm-audit.json"

log() { echo "  $1"; }

echo "Running security scans..."

# 1. Human-readable audit (for the report)
log "Running npm audit (human-readable)..."
npm audit --audit-level=high 2>&1 | tee "$AUDIT_LOG" >/dev/null || true

# 2. Machine-readable audit for accurate counts
log "Running npm audit --json..."
# npm audit exits non-zero when vulns are found; capture regardless.
npm audit --json >"$AUDIT_JSON" 2>/dev/null || true

# Parse counts. Prefer jq; fall back to grep-only on the JSON if jq is absent.
CRITICAL=0
HIGH=0
if command -v jq >/dev/null 2>&1 && [[ -s "$AUDIT_JSON" ]]; then
  # npm v7+ shape: .metadata.vulnerabilities.{critical,high,moderate,low,info}
  CRITICAL=$(jq -r '.metadata.vulnerabilities.critical // 0' "$AUDIT_JSON" 2>/dev/null || echo 0)
  HIGH=$(jq -r '.metadata.vulnerabilities.high // 0' "$AUDIT_JSON" 2>/dev/null || echo 0)
elif [[ -s "$AUDIT_JSON" ]]; then
  # Crude fallback — extract first occurrence of "critical": N and "high": N
  CRITICAL=$(grep -oE '"critical"[[:space:]]*:[[:space:]]*[0-9]+' "$AUDIT_JSON" | head -1 | grep -oE '[0-9]+$' || echo 0)
  HIGH=$(grep -oE '"high"[[:space:]]*:[[:space:]]*[0-9]+' "$AUDIT_JSON" | head -1 | grep -oE '[0-9]+$' || echo 0)
fi
CRITICAL=${CRITICAL:-0}
HIGH=${HIGH:-0}

echo "Critical vulnerabilities: $CRITICAL"
echo "High vulnerabilities:     $HIGH"

if [[ "$CRITICAL" -gt 0 ]]; then
  echo "[FAIL] $CRITICAL critical vulnerabilities found"
  exit 1
elif [[ "$HIGH" -gt 0 ]]; then
  echo "[WARN] $HIGH high-severity vulnerabilities found (non-fatal)"
  exit 0
else
  echo "[PASS] No critical/high vulnerabilities found"
  exit 0
fi
