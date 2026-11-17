#!/usr/bin/env bash
# Post-deploy health: containers, HTTP health endpoints, inbound ingress, DB sizes.
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_env
require_cmd docker curl

rc=0
check() { if "$@"; then :; else rc=1; fi; }

log "containers"
mapfile -t ids < <(docker ps -aq --filter 'name=^ss-')
(( ${#ids[@]} > 0 )) || die "no ss-* containers — run: make up"
while read -r name state health code; do
  name="${name#/}"
  case "$state/$health" in
    running/healthy|running/none) ok "$name running [health: $health]" ;;
    exited/none) if [[ "$name" == ss-chatwoot-migrate && "$code" == 0 ]]; then ok "$name completed"
                 else fail "$name exited ($code)"; rc=1; fi ;;
    *) fail "$name $state ($health)"; rc=1 ;;
  esac
done < <(docker inspect -f '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}}' "${ids[@]}")

# shellcheck disable=SC2329  # invoked via `check http_get`
http_get() {
  local label="$1" url="$2" expect="$3" body
  body="$(curl -fsS --max-time 5 "$url" 2>/dev/null)" && [[ "$body" == *"$expect"* ]] \
    && ok "$label $url" || { fail "$label $url"; return 1; }
}

log "http (loopback)"
check http_get chatwoot "http://${CHATWOOT_BIND}/health" woot
check http_get listmonk "http://${LISTMONK_BIND}/health" true

log "inbound mail ingress"
# Wrong password must be rejected (401) and the route must exist (not 404).
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -u actionmailbox:wrong \
  -H 'Content-Type: message/rfc822' --data-binary 'x' \
  "http://${CHATWOOT_BIND}/rails/action_mailbox/relay/inbound_emails" || true)"
[[ "$code" == 401 ]] && ok "relay ingress present and auth-protected" || { fail "relay ingress returned $code (want 401)"; rc=1; }

log "public hostnames"
for h in "$SUPPORT_HOST" "$LISTS_HOST"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$h/" || true)"
  [[ "$code" =~ ^(200|301|302)$ ]] && ok "https://$h -> $code" || warn "https://$h -> ${code:-no answer} (proxy/DNS not wired yet?)"
done

log "database"
docker exec ss-postgres psql -U postgres -Atc \
  "select datname || ': ' || pg_size_pretty(pg_database_size(datname)) from pg_database where datname in ('chatwoot','listmonk')" \
  2>/dev/null | sed 's/^/  /' || warn "postgres not reachable"

exit "$rc"
