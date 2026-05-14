#!/usr/bin/env bash
# Check 05: Production readiness (static review of container contract)
# Pass: Dockerfile / compose / .dockerignore meet baseline production practices
#
# Runs before Docker build (Check 06) so failures are fast and log-friendly.

set -euo pipefail

cd "$APP_ROOT"
PROD_PASS=0
PROD_FAIL=0

check_pass() { echo "[PASS] $1"; PROD_PASS=$((PROD_PASS + 1)); }
check_fail() { echo "[FAIL] $1"; PROD_FAIL=$((PROD_FAIL + 1)); }
log() { echo "  $1"; }

echo "Checking production / container contract..."

log "Dockerfile present..."
if [[ -f "$APP_ROOT/Dockerfile" ]]; then
  check_pass "Dockerfile exists"
else
  check_fail "Dockerfile missing — add one for deployable artifacts"
fi

log ".dockerignore present..."
if [[ -f "$APP_ROOT/.dockerignore" ]]; then
  check_pass ".dockerignore exists"
else
  check_fail ".dockerignore missing — images will bloat and leak dev files"
fi

log "docker-compose present..."
COMPOSE=""
if [[ -f "$APP_ROOT/docker-compose.yml" ]]; then
  COMPOSE="$APP_ROOT/docker-compose.yml"
elif [[ -f "$APP_ROOT/docker-compose.yaml" ]]; then
  COMPOSE="$APP_ROOT/docker-compose.yaml"
fi
if [[ -n "$COMPOSE" ]]; then
  check_pass "docker-compose file exists"
else
  check_fail "docker-compose.yml (or .yaml) missing"
fi

log "Non-root USER in Dockerfile..."
if [[ -f "$APP_ROOT/Dockerfile" ]]; then
  if grep -qE '^[[:space:]]*USER[[:space:]]+root([[:space:]]|$)' "$APP_ROOT/Dockerfile"; then
    check_fail "Dockerfile must not end with USER root"
  elif grep -qE '^[[:space:]]*USER[[:space:]]' "$APP_ROOT/Dockerfile"; then
    check_pass "Dockerfile sets USER (non-root expected)"
  else
    check_fail "Dockerfile must set USER to a non-root account"
  fi
fi

log "HEALTHCHECK in Dockerfile..."
if [[ -f "$APP_ROOT/Dockerfile" ]] && grep -qiE '^[[:space:]]*HEALTHCHECK' "$APP_ROOT/Dockerfile"; then
  check_pass "Dockerfile defines HEALTHCHECK"
elif [[ -f "$APP_ROOT/Dockerfile" ]]; then
  check_fail "Dockerfile missing HEALTHCHECK"
fi

log "Production dependencies install..."
if [[ -f "$APP_ROOT/Dockerfile" ]]; then
  if grep -qE 'npm[[:space:]]+ci' "$APP_ROOT/Dockerfile" && grep -qE '--omit=dev|--only=production' "$APP_ROOT/Dockerfile"; then
    check_pass "Dockerfile uses npm ci with dev deps omitted"
  elif grep -qE 'npm[[:space:]]+ci' "$APP_ROOT/Dockerfile"; then
    check_fail "Dockerfile should use npm ci --omit=dev (or equivalent) for production"
  else
    check_fail "Dockerfile should use npm ci for reproducible installs"
  fi
fi

log "NODE_ENV in container path..."
NODE_ENV_OK=0
if [[ -f "$APP_ROOT/Dockerfile" ]] && grep -qE 'NODE_ENV=production|ENV[[:space:]]+NODE_ENV[[:space:]]+production' "$APP_ROOT/Dockerfile"; then
  NODE_ENV_OK=1
fi
if [[ -n "$COMPOSE" ]] && grep -qE 'NODE_ENV.*production' "$COMPOSE"; then
  NODE_ENV_OK=1
fi
if [[ $NODE_ENV_OK -eq 1 ]]; then
  check_pass "NODE_ENV=production set in Dockerfile and/or compose"
else
  check_fail "Set NODE_ENV=production in Dockerfile or docker-compose environment"
fi

log ".dockerignore excludes node_modules..."
if [[ -f "$APP_ROOT/.dockerignore" ]] && grep -qE '^node_modules/?$|^node_modules$' "$APP_ROOT/.dockerignore"; then
  check_pass ".dockerignore excludes node_modules"
elif [[ -f "$APP_ROOT/.dockerignore" ]]; then
  check_fail ".dockerignore should list node_modules"
fi

log "Liveness route /health (app or compose healthcheck)..."
HEALTH_ROUTE=0
if grep -Rq "/health" "$APP_ROOT/src" 2>/dev/null; then
  HEALTH_ROUTE=1
fi
if [[ -f "$APP_ROOT/Dockerfile" ]] && grep -q "/health" "$APP_ROOT/Dockerfile"; then
  HEALTH_ROUTE=1
fi
if [[ $HEALTH_ROUTE -eq 1 ]]; then
  check_pass "/health referenced in source or Dockerfile"
else
  check_fail "Expose GET /health for orchestration (see app wiring + HEALTHCHECK)"
fi

echo ""
echo "Production checks: $PROD_PASS passed, $PROD_FAIL failed"

if [[ $PROD_FAIL -eq 0 ]]; then
  exit 0
fi
exit 1
