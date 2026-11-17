#!/usr/bin/env bash
# Bring the stack up (idempotent) and block until it's healthy.
#   scripts/up.sh          start / reconcile
#   scripts/up.sh --pull   pull pinned images first (used by `make upgrade`)
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_env
require_cmd docker

# The edge network is only used when a proxy *container* fronts the stack;
# create it so compose never fails on the external reference.
if ! docker network inspect "$EDGE_NETWORK" >/dev/null 2>&1; then
  docker network create "$EDGE_NETWORK" >/dev/null && ok "created network $EDGE_NETWORK"
fi

if [[ "${1:-}" == "--pull" ]]; then
  log "pulling images"
  compose pull --quiet
fi

log "starting"
compose up -d --remove-orphans

log "waiting for chatwoot migrations"
while [[ "$(docker inspect -f '{{.State.Status}}' ss-chatwoot-migrate 2>/dev/null)" =~ ^(created|running)$ ]]; do
  sleep 3
done
code="$(docker inspect -f '{{.State.ExitCode}}' ss-chatwoot-migrate)"
if [[ "$code" != 0 ]]; then
  docker logs --tail 60 ss-chatwoot-migrate >&2 || true
  die "chatwoot migrations failed (exit $code) — web/worker were not started"
fi
ok "migrations applied"

wait_healthy ss-postgres ss-redis ss-chatwoot ss-listmonk
compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
