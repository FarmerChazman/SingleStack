#!/usr/bin/env bash
# Read-only checks before `make up`. Exit 1 on blockers, warnings are advisory.
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

blockers=0
block() { fail "$*"; blockers=$((blockers + 1)); }

log "tooling"
require_cmd docker openssl
if docker compose version >/dev/null 2>&1; then
  ok "docker compose $(docker compose version --short)"
else
  block "docker compose v2 plugin not found"
fi
docker info >/dev/null 2>&1 && ok "docker daemon reachable" || block "cannot talk to docker daemon (are you in the docker group?)"

log "configuration (.env)"
load_env
if grep -q '__GENERATE__' "$ENV_FILE"; then
  block "unfilled __GENERATE__ values — run init-env.sh on a fresh copy"
fi
for k in DOMAIN SUPPORT_HOST LISTS_HOST CHATWOOT_SMTP_USER CHATWOOT_SMTP_KEY CHATWOOT_INBOUND_DOMAIN; do
  if [[ -z "${!k:-}" ]]; then block "$k is empty"; fi
done
[[ "${DOMAIN:-}" == "example.com" ]] && block "DOMAIN is still example.com"
perms="$(stat -c %a "$ENV_FILE" 2>/dev/null || echo '?')"
[[ "$perms" == "600" ]] && ok ".env mode 600" || warn ".env mode is $perms — run: chmod 600 .env"
if compose config -q 2>/tmp/ss-compose-err; then
  ok "compose.yaml + .env render cleanly"
else
  block "compose config failed: $(head -3 /tmp/ss-compose-err)"
fi

log "host ports (loopback binds)"
for bind in "$CHATWOOT_BIND" "$LISTMONK_BIND"; do
  host="${bind%:*}" port="${bind##*:}"
  [[ "$host" == "127.0.0.1" ]] || warn "$bind is not loopback — the UI would be exposed on that interface"
  owner="$(docker ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null | head -1)"
  if [[ -n "$owner" && "$owner" != ss-* ]]; then
    block "$bind already published by container '$owner'"
  elif [[ -z "$owner" ]] && port_in_use "$host" "$port"; then
    block "$bind is in use by a host process (sudo ss -ltnp 'sport = :$port')"
  else
    ok "$bind available${owner:+ (ours: $owner)}"
  fi
done

log "edge network"
if docker network inspect "$EDGE_NETWORK" >/dev/null 2>&1; then
  attached="$(docker network inspect "$EDGE_NETWORK" -f '{{range .Containers}}{{.Name}} {{end}}')"
  ok "network '$EDGE_NETWORK' exists${attached:+ — attached: $attached}"
else
  ok "network '$EDGE_NETWORK' will be created by make up (only used by proxy containers)"
fi

log "resources"
avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
(( avail_kb > 4 * 1024 * 1024 )) && ok "memory available: $((avail_kb / 1024 / 1024)) GiB" \
  || warn "only $((avail_kb / 1024)) MiB available; the stack wants ~3-4 GiB"
docker_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
free_gb="$(df -BG --output=avail "$docker_root" 2>/dev/null | tail -1 | tr -dc 0-9)"
(( ${free_gb:-0} >= 10 )) && ok "disk free at $docker_root: ${free_gb}G" || warn "low disk at $docker_root: ${free_gb:-?}G"

log "network reachability"
for h in "$SUPPORT_HOST" "$LISTS_HOST"; do
  getent hosts "$h" >/dev/null 2>&1 && ok "$h resolves" || warn "$h does not resolve yet (fine before DNS cut-over)"
done
if timeout 5 bash -c "exec 3<>/dev/tcp/${BREVO_SMTP_HOST}/${BREVO_SMTP_PORT}" 2>/dev/null; then
  ok "outbound ${BREVO_SMTP_HOST}:${BREVO_SMTP_PORT} reachable"
else
  block "cannot reach ${BREVO_SMTP_HOST}:${BREVO_SMTP_PORT} (host firewall / provider egress?)"
fi

echo
if (( blockers > 0 )); then
  die "$blockers blocker(s) — fix and re-run"
fi
ok "preflight passed — next: make up"
