#!/usr/bin/env bash
# Check 06: Functional contract — Spin up Docker stack, run per-endpoint
# contract assertions covering auth, routing, and resource CRUD.
#
# Each assertion verifies BOTH an HTTP status code AND a jq predicate against
# the response body. Cookies set by Secure-flagged Set-Cookie headers are
# extracted manually and re-sent as Cookie headers — necessary because the
# agent typically pins NODE_ENV=production (→ secure: true on auth cookies),
# while the smoke endpoint runs over plain HTTP.

set -euo pipefail

cd "$APP_ROOT"
FUNC_LOG="$RESULTS_DIR/functional-log.txt"
RESP_DIR="$RESULTS_DIR/contract-responses"
mkdir -p "$RESP_DIR"

log()  { echo "  $1"; echo "$1" >>"$FUNC_LOG"; }
note() { echo "  [INFO] $1"; }

# -----------------------------------------------------------------------------
# Compose binary
# -----------------------------------------------------------------------------
if [[ -z "${DOCKER_COMPOSE:-}" ]]; then
  if command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
  elif docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
  else
    log "[FAIL] No docker compose binary found"
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# Find compose file
# -----------------------------------------------------------------------------
if [[ -f "$APP_ROOT/docker-compose.yml" ]]; then
  COMPOSE_FILE="$APP_ROOT/docker-compose.yml"
elif [[ -f "$APP_ROOT/docker-compose.yaml" ]]; then
  COMPOSE_FILE="$APP_ROOT/docker-compose.yaml"
else
  log "[FAIL] No docker-compose.yml found"
  exit 1
fi

APP_PORT=${APP_PORT:-3000}
APP_HOST=${APP_HOST:-localhost}
APP_URL="http://$APP_HOST:$APP_PORT"

cleanup() {
  log "Tearing down Docker stack..."
  $DOCKER_COMPOSE -f "$COMPOSE_FILE" down --volumes --remove-orphans >>"$FUNC_LOG" 2>&1 || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Boot
# -----------------------------------------------------------------------------
log "Building Docker images..."
$DOCKER_COMPOSE -f "$COMPOSE_FILE" build >>"$FUNC_LOG" 2>&1 || {
  log "[FAIL] Docker build failed"; exit 1;
}

log "Starting stack..."
$DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d >>"$FUNC_LOG" 2>&1 || {
  log "[FAIL] Docker compose up failed"; exit 1;
}

log "Waiting for app to start (max 60s)..."
for i in $(seq 1 30); do
  if curl -sf "$APP_URL/health" >>"$FUNC_LOG" 2>&1; then
    log "App is up (/health)"
    break
  fi
  if [[ $i -eq 30 ]]; then
    log "[FAIL] App did not start within 60s"
    $DOCKER_COMPOSE -f "$COMPOSE_FILE" logs >>"$FUNC_LOG" 2>&1
    exit 1
  fi
  sleep 2
done

# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------
PASS=0
FAIL=0
COOKIE=""   # set by extract_cookie

# Issue a request; write body to "$1" (file path); write headers to "$1.hdr";
# echo HTTP status code. Optional flags via env:
#   COOKIE  — if non-empty, sent as `Cookie: $COOKIE`
http_req() {
  local out="$1"; local method="$2"; local path="$3"; local body="${4:-}"
  local -a args=(-sS -o "$out" -D "$out.hdr" -w "%{http_code}")
  if [[ -n "$COOKIE" ]]; then args+=(-H "Cookie: $COOKIE"); fi
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" -X "$method" --data "$body")
  else
    args+=(-X "$method")
  fi
  curl "${args[@]}" "${APP_URL}${path}" 2>>"$FUNC_LOG" || echo "000"
}

# Extract the auth cookie value from the most recent response's headers file.
# Sets COOKIE to "<name>=<value>". Returns 1 if no Set-Cookie present.
extract_cookie() {
  local hdr_file="$1"
  local line
  line=$(grep -i '^Set-Cookie:' "$hdr_file" 2>/dev/null | head -1 || true)
  [[ -z "$line" ]] && return 1
  # Strip "Set-Cookie:" prefix, take everything before the first ';' (drop attrs)
  COOKIE=$(echo "$line" | sed -E 's/^[Ss]et-[Cc]ookie:[[:space:]]*//; s/;.*$//; s/[[:space:]]+$//')
  return 0
}

# Run one contract test.
#   $1 — short ID  (e.g. C01)
#   $2 — description
#   $3 — expected status (e.g. 201)  OR a regex like "^2[0-9][0-9]$"
#   $4 — jq predicate against body (use 'true' to skip body assertion)
#   $5 — body file (already populated by http_req)
assert_contract() {
  local id="$1" desc="$2" want="$3" jq_pred="$4" body="$5"
  local got
  got=$(cat "$body.code" 2>/dev/null || echo "000")
  local status_ok=0
  if [[ "$want" =~ ^[0-9]+$ ]]; then
    [[ "$got" == "$want" ]] && status_ok=1
  else
    [[ "$got" =~ $want ]] && status_ok=1
  fi

  local body_ok=1
  if [[ "$jq_pred" != "true" ]]; then
    if ! jq -e "$jq_pred" "$body" >/dev/null 2>&1; then
      body_ok=0
    fi
  fi

  if [[ $status_ok -eq 1 && $body_ok -eq 1 ]]; then
    echo "[PASS] $id $desc (status $got)"
    PASS=$((PASS + 1))
  else
    local reason=""
    [[ $status_ok -eq 0 ]] && reason="status $got≠$want"
    [[ $body_ok -eq 0 ]] && reason="${reason:+$reason; }body fails jq: $jq_pred"
    echo "[FAIL] $id $desc ($reason; body: $(head -c 200 "$body" 2>/dev/null))"
    FAIL=$((FAIL + 1))
  fi
}

# Convenience: issue req + capture status + dispatch to assert
run_case() {
  local id="$1" desc="$2" method="$3" path="$4" body_json="$5" want="$6" jq_pred="$7"
  local body_file="$RESP_DIR/$id.json"
  local code
  code=$(http_req "$body_file" "$method" "$path" "$body_json")
  echo "$code" >"$body_file.code"
  assert_contract "$id" "$desc" "$want" "$jq_pred" "$body_file"
}

# -----------------------------------------------------------------------------
# Test setup — synthesize a unique user so re-runs don't collide
# -----------------------------------------------------------------------------
USER="eval_$(date +%s)_$$"
PASS_WORD="Password123!"
USER_JSON="{\"username\":\"$USER\",\"email\":\"${USER}@example.com\",\"password\":\"$PASS_WORD\"}"
WRONG_PW_JSON="{\"username\":\"$USER\",\"password\":\"wrong-password\"}"

# Discover the auth path family (typically /api/auth, but try variants).
discover_auth_base() {
  for p in /api/auth /auth /api; do
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -X POST --data '{}' "${APP_URL}${p}/signup" 2>>"$FUNC_LOG" || echo "000")
    if [[ "$code" != "404" && "$code" != "000" && ! "$code" =~ ^5[0-9][0-9]$ ]]; then
      echo "$p"
      return 0
    fi
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -X POST --data '{}' "${APP_URL}${p}/register" 2>>"$FUNC_LOG" || echo "000")
    if [[ "$code" != "404" && "$code" != "000" && ! "$code" =~ ^5[0-9][0-9]$ ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

AUTH_BASE=$(discover_auth_base) || true
if [[ -z "$AUTH_BASE" ]]; then
  echo "[FAIL] Could not find auth signup route at /api/auth, /auth, or /api"
  FAIL=$((FAIL + 1))
  AUTH_BASE="/api/auth"  # fall through so we record more failures
fi
note "Auth base: $AUTH_BASE"

# Decide signup verb (signup vs register) by probing
SIGNUP_PATH="$AUTH_BASE/signup"
probe=$(curl -sS -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -X POST --data '{}' "${APP_URL}$SIGNUP_PATH" 2>>"$FUNC_LOG" || echo "000")
if [[ "$probe" == "404" ]]; then
  SIGNUP_PATH="$AUTH_BASE/register"
fi
LOGIN_PATH="$AUTH_BASE/login"
ME_PATH="$AUTH_BASE/me"
LOGOUT_PATH="$AUTH_BASE/logout"
note "Auth paths: signup=$SIGNUP_PATH login=$LOGIN_PATH me=$ME_PATH logout=$LOGOUT_PATH"

log ""
log "=== Auth contract ==="

# C01 — health
run_case "C01" "GET /health is JSON 200" \
  GET "/health" "" "200" '. | type == "object"'

# C02 — signup valid
SIGNUP_BODY="$RESP_DIR/C02.json"
CODE=$(http_req "$SIGNUP_BODY" POST "$SIGNUP_PATH" "$USER_JSON")
echo "$CODE" >"$SIGNUP_BODY.code"
assert_contract "C02" "POST $SIGNUP_PATH valid → 2xx + non-empty body" \
  "^2[0-9][0-9]$" '. != null and (. | length > 0)' "$SIGNUP_BODY"

# C03 — capture cookie from signup
if extract_cookie "$SIGNUP_BODY.hdr"; then
  echo "[PASS] C03 Set-Cookie present on signup (cookie=$COOKIE)"
  PASS=$((PASS + 1))
else
  echo "[FAIL] C03 Set-Cookie missing on signup — auth flow can't continue"
  FAIL=$((FAIL + 1))
fi

# C04 — signup with missing password should fail with a 4xx + non-empty error-ish body
run_case "C04" "POST $SIGNUP_PATH missing password → 4xx + body has 'error' key" \
  POST "$SIGNUP_PATH" "{\"username\":\"missing_pw_$USER\"}" \
  "^4[0-9][0-9]$" 'has("error") or has("message") or has("errors")'

# C05 — duplicate signup
run_case "C05" "POST $SIGNUP_PATH duplicate username → 4xx" \
  POST "$SIGNUP_PATH" "$USER_JSON" \
  "^4[0-9][0-9]$" 'true'

# C06 — login wrong password
run_case "C06" "POST $LOGIN_PATH wrong password → 4xx" \
  POST "$LOGIN_PATH" "$WRONG_PW_JSON" \
  "^4[0-9][0-9]$" 'true'

# C07 — login correct password returns 2xx + sets cookie
LOGIN_BODY="$RESP_DIR/C07.json"
CODE=$(COOKIE="" http_req "$LOGIN_BODY" POST "$LOGIN_PATH" "$USER_JSON")
echo "$CODE" >"$LOGIN_BODY.code"
assert_contract "C07" "POST $LOGIN_PATH valid → 2xx" \
  "^2[0-9][0-9]$" '. != null' "$LOGIN_BODY"
if extract_cookie "$LOGIN_BODY.hdr"; then
  echo "[PASS] C08 login resets Set-Cookie (cookie=$COOKIE)"
  PASS=$((PASS + 1))
else
  echo "[FAIL] C08 login did not Set-Cookie"
  FAIL=$((FAIL + 1))
fi

# C09 — protected GET /me without cookie → 401/403
SAVED_COOKIE="$COOKIE"; COOKIE=""
run_case "C09" "GET $ME_PATH without auth → 401/403" \
  GET "$ME_PATH" "" \
  "^40[13]$" 'true'
COOKIE="$SAVED_COOKIE"

# C10 — GET /me with cookie → 2xx + has user-ish field somewhere in body
run_case "C10" "GET $ME_PATH with auth → 2xx + body has user identity" \
  GET "$ME_PATH" "" \
  "^2[0-9][0-9]$" 'any(.. | objects; has("username") or has("id") or has("email"))'

# -----------------------------------------------------------------------------
# Resource CRUD — discover the protected resource surface
# Tries the most common collection-resource names. Picks the first one that
# responds 2xx when called with the auth cookie. If none match, the resource
# tests are skipped cleanly (with INFO lines, not FAIL).
# -----------------------------------------------------------------------------
log ""
log "=== Resource contract ==="

discover_resource_base() {
  local prefix candidate code
  for prefix in "/api" ""; do
    for candidate in habits todos tasks items posts notes projects articles products entries records; do
      code=$(curl -sS -o /dev/null -w "%{http_code}" \
        -H "Cookie: $COOKIE" "${APP_URL}${prefix}/${candidate}" 2>>"$FUNC_LOG" || echo "000")
      if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        echo "${prefix}/${candidate}"
        return 0
      fi
    done
  done
  return 1
}

RES_BASE=$(discover_resource_base) || RES_BASE=""

if [[ -z "$RES_BASE" ]]; then
  note "No protected resource collection discovered at /api/{habits,todos,tasks,...} — skipping C11–C14"
else
  note "Discovered resource base: $RES_BASE"

  # C11 — GET resource without auth → 401
  SAVED_COOKIE="$COOKIE"; COOKIE=""
  run_case "C11" "GET $RES_BASE without auth → 401/403" \
    GET "$RES_BASE" "" \
    "^40[13]$" 'true'
  COOKIE="$SAVED_COOKIE"

  # C12 — POST a resource (best-effort: includes several common field names so
  # the same probe works whether the agent expects name/title/content/text).
  NEW_RESOURCE='{"name":"eval-harness probe","title":"eval-harness probe","content":"x","text":"x"}'
  RES_BODY="$RESP_DIR/C12.json"
  CODE=$(http_req "$RES_BODY" POST "$RES_BASE" "$NEW_RESOURCE")
  echo "$CODE" >"$RES_BODY.code"
  assert_contract "C12" "POST $RES_BASE with auth → 2xx + body has id-ish field" \
    "^2[0-9][0-9]$" 'any(.. | objects; has("id"))' "$RES_BODY"

  # Extract a resource id for follow-up tests (skip downstream if not present)
  RES_ID=$(jq -r '[.. | objects | select(has("id")) | .id] | first // empty' "$RES_BODY" 2>/dev/null || true)

  # C13 — GET resource list
  LIST_BODY="$RESP_DIR/C13.json"
  CODE=$(http_req "$LIST_BODY" GET "$RES_BASE" "")
  echo "$CODE" >"$LIST_BODY.code"
  assert_contract "C13" "GET $RES_BASE with auth → 2xx + body contains an array" \
    "^2[0-9][0-9]$" 'any(.. | arrays; true)' "$LIST_BODY"

  # C14 — interaction on a specific resource. Try the discovered conventional
  # actions (complete, done, toggle) — accept any 2xx; 404 means the action
  # route doesn't exist (informational, not a failure).
  if [[ -n "$RES_ID" ]]; then
    ACTION_FOUND=""
    for action in complete done toggle finish; do
      CMP_BODY="$RESP_DIR/C14-$action.json"
      CODE=$(http_req "$CMP_BODY" POST "$RES_BASE/$RES_ID/$action" "")
      echo "$CODE" >"$CMP_BODY.code"
      if [[ "$CODE" =~ ^2[0-9][0-9]$ ]]; then
        ACTION_FOUND="$action"
        assert_contract "C14" "POST $RES_BASE/:id/$action → 2xx" \
          "^2[0-9][0-9]$" 'true' "$CMP_BODY"
        break
      fi
    done
    if [[ -z "$ACTION_FOUND" ]]; then
      note "C14: no action verb (complete/done/toggle/finish) is exposed on $RES_BASE/:id — skipping"
    fi
  else
    note "Skipping C14 — no resource id captured from C12"
  fi
fi

# -----------------------------------------------------------------------------
# Routing hygiene
# -----------------------------------------------------------------------------
log ""
log "=== Routing hygiene ==="

# C15 — unknown route returns 404
run_case "C15" "GET /this-route-does-not-exist → 404" \
  GET "/this-route-does-not-exist-$RANDOM" "" \
  "404" 'true'

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
TOTAL=$((PASS + FAIL))
echo "Contract: $PASS passed, $FAIL failed (of $TOTAL)"
if [[ $FAIL -eq 0 ]]; then
  log "[PASS] All contract assertions passed ($PASS checks)"
  exit 0
else
  log "[FAIL] Contract: $FAIL failures"
  exit 1
fi
