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

check_pass() { echo "[PASS] $1"; ((CONV_PASS++)); }
check_fail() { echo "[FAIL] $1"; ((CONV_FAIL++)); }

log() { echo "  $1"; }

echo "Checking scaffold conventions..."

# 1. DAL — all SQL queries in src/dal/
log "DAL separation check..."
SQL_IN_DAL=$(grep -r "db.prepare\|db.query\|db.exec\|SELECT\|INSERT\|UPDATE\|DELETE" "$APP_ROOT/src/dal/" 2>/dev/null | wc -l || 0)
SQL_OUTSIDE_DAL=$(grep -rn "db.prepare\|db.query\|db.exec\|SELECT\|INSERT\|UPDATE\|DELETE" "$APP_ROOT/src/routes/" "$APP_ROOT/src/services/" 2>/dev/null | grep -v "dal\|DAL" | wc -l || 0)
if [[ $SQL_OUTSIDE_DAL -eq 0 ]] && [[ $SQL_IN_DAL -gt 0 ]]; then
  check_pass "All DB access in src/dal/ ($SQL_IN_DAL queries found)"
elif [[ $SQL_OUTSIDE_DAL -gt 0 ]]; then
  check_fail "Raw SQL found outside src/dal/ ($SQL_OUTSIDE_DAL occurrences)"
  grep -rn "db.prepare\|db.query\|SELECT\|INSERT\|UPDATE\|DELETE" "$APP_ROOT/src/routes/" "$APP_ROOT/src/services/" 2>/dev/null | grep -v "dal\|DAL" | head -5
else
  check_fail "No SQL found in src/dal/ — DAL may not be implemented"
fi

# 2. Error envelope format — { error, code } in responses
log "Error envelope check..."
ERROR_ENVELOPE=$(grep -r "error.*code\|\.error\s*=" "$APP_ROOT/src/" 2>/dev/null | grep -v "errorEnvelope\|\.error =" | wc -l || 0)
WRONG_ERROR=$(grep -rn 'res\.json.*message:\|res\.json.*msg:\|res\.json.*"message"\|res\.json.*{ msg' "$APP_ROOT/src/routes/" 2>/dev/null | wc -l || 0)
if [[ $WRONG_ERROR -eq 0 ]] && [[ $ERROR_ENVELOPE -gt 0 ]]; then
  check_pass "Error envelope format used correctly"
elif [[ $WRONG_ERROR -gt 0 ]]; then
  check_fail "Non-standard error format found (should be { error, code })"
else
  check_fail "No error handling found"
fi

# 3. Naming conventions — kebab-case files, camelCase functions
log "Naming conventions check..."
NON_KEBAB=$(find "$APP_ROOT/src" -name "*.js" 2>/dev/null | xargs -I{} basename {} | grep -v "^-" | grep -E "[A-Z]|_" | head -5 || true)
if [[ -z "$NON_KEBAB" ]]; then
  check_pass "Files use kebab-case"
else
  check_fail "Non-kebab-case files found: $NON_KEBAB"
fi

# 4. Graceful shutdown — SIGTERM handler
log "Graceful shutdown check..."
if grep -rq "SIGTERM\|SIGINT\|shutdown" "$APP_ROOT/src/index.js" 2>/dev/null; then
  check_pass "Graceful shutdown implemented"
else
  check_fail "No SIGTERM/SIGINT shutdown handler found"
fi

# 5. Auth guards — requireAuth middleware on protected routes
log "Auth guards check..."
PROTECTED_ROUTES=$(grep -r "router\.\(get\|post\|put\|delete\|patch\)" "$APP_ROOT/src/routes/" 2>/dev/null | wc -l || 0)
AUTH_GUARDS=$(grep -r "requireAuth\|require-auth\|isAuthenticated" "$APP_ROOT/src/routes/" 2>/dev/null | wc -l || 0)
if [[ $AUTH_GUARDS -ge 3 ]]; then  # At least a few routes have auth
  check_pass "Auth guards found on protected routes"
else
  check_fail "Auth guards may be missing (found $AUTH_GUARDS uses of requireAuth)"
fi

# 6. Secrets — no hardcoded values
log "Secrets check (no hardcoded credentials)..."
HARDCODED=$(grep -rn "password\s*=\s*['\"][^$][^'\"]*['\"]\|api_key\s*=\s*['\"][^$][^'\"]*['\"]\|secret\s*=\s*['\"][^$][^'\"]*['\"]" "$APP_ROOT/src/" 2>/dev/null | grep -v "\.env\|\.example\|process\.env" | head -5 || true)
if [[ -z "$HARDCODED" ]]; then
  check_pass "No obvious hardcoded secrets found"
else
  check_fail "Possible hardcoded secrets found: $HARDCODED"
fi

# 7. Business logic in services
log "Business logic separation check..."
ROUTE_WITH_LOGIC=$(grep -rn "if.*==\|for.*\|while\|SELECT\|INSERT" "$APP_ROOT/src/routes/" 2>/dev/null | grep -v "require\|import\|throw\|return" | wc -l || 0)
if [[ $ROUTE_WITH_LOGIC -lt 3 ]]; then
  check_pass "Route handlers mostly thin (business logic in services)"
else
  check_fail "Route handlers may contain business logic ($ROUTE_WITH_LOGIC logic statements found)"
fi

# 8. SESSION.md handoff template present
log "SESSION.md check..."
if [[ -f "$APP_ROOT/SESSION.md" ]]; then
  check_pass "SESSION.md handoff template present"
else
  check_fail "SESSION.md not found — no session handoff template"
fi

# Summary
echo ""
echo "Conventions: $CONV_PASS passed, $CONV_FAIL failed"

if [[ $CONV_FAIL -eq 0 ]]; then
  exit 0
else
  exit 1
fi
