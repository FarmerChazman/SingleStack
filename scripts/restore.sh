#!/usr/bin/env bash
# Restore a backup made by backup.sh. DESTRUCTIVE: replaces both databases
# and both file volumes.
#   scripts/restore.sh backups/20261117T023000Z
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_env
require_cmd docker sha256sum

src="${1:-}"
[[ -d "$src" ]] || die "usage: $0 <backup-dir>"
src="$(cd "$src" && pwd)"

log "verifying checksums"
(cd "$src" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch in $src"
ok "checksums match"

if ! cmp -s <(grep -E '^CHATWOOT_SECRET_KEY_BASE=' "$src/env") <(grep -E '^CHATWOOT_SECRET_KEY_BASE=' "$ENV_FILE"); then
  warn "CHATWOOT_SECRET_KEY_BASE differs from the backup's — encrypted fields won't decrypt."
  warn "copy it from $src/env into .env first unless you know you don't need them."
fi

echo
echo "This replaces the chatwoot + listmonk databases and files with:"
sed 's/^/    /' "$src/MANIFEST"
read -r -p "Type the project name (${COMPOSE_PROJECT_NAME}) to continue: " answer
[[ "$answer" == "$COMPOSE_PROJECT_NAME" ]] || die "aborted"

log "stopping app containers"
compose stop chatwoot-web chatwoot-worker listmonk
compose up -d postgres redis
wait_healthy ss-postgres ss-redis

for db in chatwoot listmonk; do
  log "restoring database: $db"
  docker exec ss-postgres psql -U postgres -v ON_ERROR_STOP=1 -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();" \
    -c "DROP DATABASE IF EXISTS $db;" \
    -c "CREATE DATABASE $db OWNER $db;" >/dev/null
  # Run as superuser so the dump's CREATE EXTENSION / ALTER ... OWNER succeed.
  docker exec -i ss-postgres pg_restore -U postgres --exit-on-error -d "$db" < "$src/$db.dump"
  ok "$db restored"
done

log "restoring files"
compose run --rm --no-deps -T --entrypoint sh chatwoot-web \
  -c 'find /app/storage -mindepth 1 -delete && tar -xzf - -C /app/storage' < "$src/chatwoot-storage.tgz"
ok "chatwoot storage"
compose run --rm --no-deps -T --entrypoint sh listmonk \
  -c 'find /listmonk/uploads -mindepth 1 -delete && tar -xzf - -C /listmonk/uploads' < "$src/listmonk-uploads.tgz"
ok "listmonk uploads"

log "starting stack (migrations run automatically)"
compose up -d
wait_healthy ss-chatwoot ss-listmonk
ok "restore complete — run: make doctor"
