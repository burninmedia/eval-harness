#!/usr/bin/env bash
# Check 03: Scaffold Conventions
# Validates:
#   - All DB access in src/dal/ (no raw SQL in routes or services)
#   - Error responses use { error, code, fields? } envelope
#   - Naming: kebab-case files, camelCase vars
#   - Graceful shutdown handled (SIGTERM/SIGINT)
#   - Auth guards on protected routes
#   - No hardcoded secrets (all config from env)
#   - Business logic in services, not route handlers

set -euo pipefail

cd "$APP_ROOT"
CONV_PASS=0
CONV_FAIL=0

check_pass() { echo "[PASS] $1"; CONV_PASS=$((CONV_PASS+1)); }
check_fail() { echo "[FAIL] $1"; CONV_FAIL=$((CONV_FAIL+1)); }

log() { echo "  $1"; }

# Count lines from a grep without tripping pipefail when grep finds nothing.
# Usage: count=$(grep_count -rE "pattern" path ...)
grep_count() {
  local n
  n=$(grep "$@" 2>/dev/null | wc -l || echo 0)
  echo "${n:-0}" | tr -d '[:space:]'
}

echo "Checking scaffold conventions..."

# 1. DAL — all DB access in src/dal/
log "DAL separation check..."
# Anchor on actual sqlite/better-sqlite3 / pg call sites instead of bare SQL keywords
# (bare keywords match comments, log strings, identifiers, and produce noise).
DAL_DIR="$APP_ROOT/src/dal"
# DB call sites — match the methods directly (covers chained calls like
# getDb().prepare(), db.prepare(), database.exec(), pool.query()).
# .prepare( and .transaction( are DB-specific enough to be reliable signals.
DB_CALL_RE='(\.(prepare|transaction|exec)[[:space:]]*\(|new[[:space:]]+Database[[:space:]]*\(|require\(['"'"'\"]better-sqlite3['"'"'\"]\))'
SQL_IN_DAL=0
SQL_OUTSIDE_DAL=0
if [[ -d "$DAL_DIR" ]]; then
  SQL_IN_DAL=$(grep_count -rE "$DB_CALL_RE" "$DAL_DIR")
fi
for dir in "$APP_ROOT/src/routes" "$APP_ROOT/src/services" "$APP_ROOT/src/controllers"; do
  if [[ -d "$dir" ]]; then
    n=$(grep_count -rE "$DB_CALL_RE" "$dir")
    SQL_OUTSIDE_DAL=$((SQL_OUTSIDE_DAL + n))
  fi
done
if [[ $SQL_OUTSIDE_DAL -eq 0 ]] && [[ $SQL_IN_DAL -gt 0 ]]; then
  check_pass "All DB access in src/dal/ ($SQL_IN_DAL call sites)"
elif [[ $SQL_OUTSIDE_DAL -gt 0 ]]; then
  check_fail "DB calls found outside src/dal/ ($SQL_OUTSIDE_DAL occurrences)"
  for dir in "$APP_ROOT/src/routes" "$APP_ROOT/src/services" "$APP_ROOT/src/controllers"; do
    [[ -d "$dir" ]] && grep -rnE "$DB_CALL_RE" "$dir" 2>/dev/null | head -5 || true
  done
else
  check_fail "No DB call sites found in src/dal/ — DAL may not be implemented"
fi

# 2. Error envelope format — { error, code } in responses
log "Error envelope check..."
ERROR_ENVELOPE=$(grep_count -rE "error['\"]?[[:space:]]*[:,].*code|code['\"]?[[:space:]]*:" "$APP_ROOT/src")
WRONG_ERROR=$(grep_count -rnE 'res\.json\([^)]*(message|msg)[[:space:]]*:' "$APP_ROOT/src/routes")
if [[ $WRONG_ERROR -eq 0 ]] && [[ $ERROR_ENVELOPE -gt 0 ]]; then
  check_pass "Error envelope format used (no { message: ... } payloads in routes)"
elif [[ $WRONG_ERROR -gt 0 ]]; then
  check_fail "Non-standard error format found ($WRONG_ERROR uses of message/msg in route json)"
else
  check_fail "No error envelope ({ error, code }) found in src/"
fi

# 3. Naming conventions — kebab-case files (excluding tests + config files)
log "Naming conventions check..."
ALLOW_RE='^(jest\.config|jest\.setup|babel\.config|eslint\.config|tailwind\.config|vite\.config|webpack\.config)\.(js|cjs|mjs|ts)$'
NON_KEBAB=$(
  find "$APP_ROOT/src" -type f -name "*.js" \
    -not -path "*/__tests__/*" \
    -not -name "*.test.js" \
    -not -name "*.spec.js" \
    2>/dev/null \
  | while read -r f; do
      b=$(basename "$f")
      [[ "$b" =~ $ALLOW_RE ]] && continue
      # Flag if filename has uppercase or underscores
      if echo "$b" | grep -qE "[A-Z_]"; then
        echo "$b"
      fi
    done | head -5 || true
)
if [[ -z "$NON_KEBAB" ]]; then
  check_pass "Files use kebab-case"
else
  check_fail "Non-kebab-case files: $(echo "$NON_KEBAB" | tr '\n' ' ')"
fi

# 4. Graceful shutdown — SIGTERM/SIGINT handler in entry point
log "Graceful shutdown check..."
ENTRY=""
for cand in "$APP_ROOT/src/index.js" "$APP_ROOT/src/server.js" "$APP_ROOT/src/app.js"; do
  [[ -f "$cand" ]] && ENTRY="$cand" && break
done
if [[ -n "$ENTRY" ]] && grep -qE "SIGTERM|SIGINT|gracefulShutdown" "$ENTRY"; then
  check_pass "Graceful shutdown implemented in $(basename "$ENTRY")"
else
  check_fail "No SIGTERM/SIGINT shutdown handler found in src/{index,server,app}.js"
fi

# 5. Auth guards — requireAuth middleware on protected routes
log "Auth guards check..."
AUTH_GUARDS=0
if [[ -d "$APP_ROOT/src/routes" ]]; then
  AUTH_GUARDS=$(grep_count -rE "requireAuth|isAuthenticated|ensureAuth" "$APP_ROOT/src/routes")
fi
if [[ $AUTH_GUARDS -ge 3 ]]; then
  check_pass "Auth guards found on protected routes ($AUTH_GUARDS references)"
else
  check_fail "Auth guards may be missing (found $AUTH_GUARDS uses of requireAuth/isAuthenticated/ensureAuth)"
fi

# 6. Secrets — no hardcoded values
log "Secrets check (no hardcoded credentials)..."
HARDCODED=$(
  grep -rnE "(password|api_key|secret)[[:space:]]*=[[:space:]]*['\"][^'\"$][^'\"]*['\"]" \
    "$APP_ROOT/src" 2>/dev/null \
  | grep -vE "process\.env|\.env|\.example" \
  | head -5 || true
)
if [[ -z "$HARDCODED" ]]; then
  check_pass "No obvious hardcoded secrets found"
else
  check_fail "Possible hardcoded secrets:"
  echo "$HARDCODED"
fi

# 7. Business logic in services — heuristic: route files shouldn't import the DAL directly
log "Thin route handlers check..."
ROUTES_USING_DAL=0
if [[ -d "$APP_ROOT/src/routes" ]]; then
  ROUTES_USING_DAL=$(grep_count -rE "require\(['\"].*dal['\"]\)|from[[:space:]]+['\"].*dal['\"]" "$APP_ROOT/src/routes")
fi
if [[ $ROUTES_USING_DAL -eq 0 ]]; then
  check_pass "Routes don't import DAL directly (thin handlers)"
else
  check_fail "Route files import DAL directly in $ROUTES_USING_DAL place(s) — push to services"
fi

# Summary
echo ""
echo "Conventions: $CONV_PASS passed, $CONV_FAIL failed"

if [[ $CONV_FAIL -eq 0 ]]; then
  exit 0
else
  exit 1
fi
