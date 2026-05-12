#!/usr/bin/env bash
# Check 05: Functional — Spin up Docker stack, smoke test endpoints
# Pass: app starts and responds to health check

set -euo pipefail

cd "$APP_ROOT"
FUNC_LOG="$RESULTS_DIR/functional-log.txt"

log() { echo "  $1"; echo "$1" >> "$FUNC_LOG"; }

# Find docker-compose file
if [[ -f "$APP_ROOT/docker-compose.yml" ]]; then
  COMPOSE_FILE="$APP_ROOT/docker-compose.yml"
elif [[ -f "$APP_ROOT/docker-compose.yaml" ]]; then
  COMPOSE_FILE="$APP_ROOT/docker-compose.yaml"
else
  log "[FAIL] No docker-compose.yml found"
  exit 1
fi

# Determine port from compose or default
APP_PORT=${APP_PORT:-3000}
APP_URL="http://localhost:$APP_PORT"

cleanup() {
  log "Tearing down Docker stack..."
  docker-compose -f "$COMPOSE_FILE" down --volumes --remove-orphans >> "$FUNC_LOG" 2>&1 || true
}
trap cleanup EXIT

log "Building Docker images..."
docker-compose -f "$COMPOSE_FILE" build >> "$FUNC_LOG" 2>&1 || {
  log "[FAIL] Docker build failed"
  exit 1
}

log "Starting stack..."
docker-compose -f "$COMPOSE_FILE" up -d >> "$FUNC_LOG" 2>&1 || {
  log "[FAIL] Docker compose up failed"
  exit 1
}

# Wait for app to be ready
log "Waiting for app to start (max 60s)..."
for i in $(seq 1 30); do
  if curl -sf "$APP_URL/health" >> "$FUNC_LOG" 2>&1; then
    log "App is up!"
    break
  fi
  if curl -sf "$APP_URL/" >> "$FUNC_LOG" 2>&1; then
    log "App is up (no /health endpoint but responding)"
    break
  fi
  if [[ $i -eq 30 ]]; then
    log "[FAIL] App did not start within 60s"
    docker-compose -f "$COMPOSE_FILE" logs >> "$FUNC_LOG" 2>&1
    exit 1
  fi
  sleep 2
done

# Smoke test key endpoints
SMOKE_PASS=0
SMOKE_FAIL=0

smoke_test() {
  local method="$1"; local path="$2"; local expected="$3"; local desc="$4"
  local resp
  resp=$(curl -sf -X "$method" "${APP_URL}${path}" -w "\n%{http_code}" 2>&1 || true)
  local code=$(echo "$resp" | tail -1)
  local body=$(echo "$resp" | head -n -1)
  if [[ "$code" == "$expected" ]] || [[ "$expected" == "2xx" && "$code" =~ ^2[0-9][0-9]$ ]]; then
    echo "[PASS] $desc ($method $path → $code)"
    ((SMOKE_PASS++))
  else
    echo "[FAIL] $desc ($method $path → expected $expected, got $code)"
    ((SMOKE_FAIL++))
  fi
}

log "Running smoke tests..."

# Unauthenticated routes should redirect to login or return 401/200
smoke_test "GET" "/dashboard" "2xx" "Dashboard accessible"
smoke_test "GET" "/api/dashboard" "401" "API dashboard requires auth"

# Auth routes should respond
smoke_test "GET" "/login" "2xx" "Login page accessible"
smoke_test "GET" "/signup" "2xx" "Signup page accessible"

# CORS / health
smoke_test "GET" "/" "2xx" "Root responds"

echo ""
if [[ $SMOKE_FAIL -eq 0 ]]; then
  log "[PASS] All smoke tests passed ($SMOKE_PASS/$SMOKE_PASS)"
  exit 0
else
  log "[FAIL] Smoke tests: $SMOKE_FAIL failures"
  exit 1
fi
