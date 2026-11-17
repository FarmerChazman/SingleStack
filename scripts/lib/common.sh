#!/usr/bin/env bash
# Shared helpers. Source from scripts:  . "$(dirname "$0")/lib/common.sh"
# shellcheck disable=SC2034  # ROOT_DIR / ENV_FILE are used by callers.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

if [[ -t 1 ]]; then
  _c_red=$'\e[31m' _c_grn=$'\e[32m' _c_ylw=$'\e[33m' _c_dim=$'\e[2m' _c_off=$'\e[0m'
else
  _c_red='' _c_grn='' _c_ylw='' _c_dim='' _c_off=''
fi

log()  { printf '%s==>%s %s\n' "$_c_dim" "$_c_off" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$_c_grn" "$_c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$_c_ylw" "$_c_off" "$*" >&2; }
fail() { printf '  %s✗%s %s\n' "$_c_red" "$_c_off" "$*" >&2; }
die()  { fail "$*"; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
  done
}

# Load KEY=value pairs from .env into the environment WITHOUT executing it
# (no `source`, so values containing <, >, $, spaces are taken literally).
load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found — run: make init DOMAIN=your-domain"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    # Strip one layer of matching quotes.
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    export "$key=$val"
  done < "$ENV_FILE"
}

# Alphanumeric only: safe in URLs, basic-auth and Rails' SECRET_KEY_BASE.
gen_secret() {
  local bytes="${1:-24}"
  openssl rand -hex "$bytes"
}

compose() {
  docker compose --project-directory "$ROOT_DIR" -f "$ROOT_DIR/compose.yaml" --env-file "$ENV_FILE" "$@"
}

# Poll until every named container reports healthy (or time out).
# Used instead of `compose up --wait`, which trips over the one-shot migrate job.
wait_healthy() {
  local timeout="${WAIT_TIMEOUT:-300}" start=$SECONDS c s pending
  while :; do
    pending=()
    for c in "$@"; do
      s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)"
      [[ "$s" == healthy ]] || pending+=("$c:$s")
    done
    (( ${#pending[@]} == 0 )) && { ok "healthy: $*"; return 0; }
    (( SECONDS - start > timeout )) && { fail "timed out after ${timeout}s waiting for: ${pending[*]}"; return 1; }
    sleep 5
  done
}

# Is something already listening on host:port? (uses ss; falls back to bash /dev/tcp)
port_in_use() {
  local host="$1" port="$2"
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "( sport = :$port )" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null
  fi
}
