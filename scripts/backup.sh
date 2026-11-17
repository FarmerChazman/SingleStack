#!/usr/bin/env bash
# Consistent-enough online backup: pg_dump per database (MVCC snapshot),
# tarballs of file volumes, and a copy of .env (Chatwoot's SECRET_KEY_BASE is
# needed to decrypt stored credentials — a DB dump without it is half a backup).
#
#   scripts/backup.sh            -> $BACKUP_DIR/<UTC timestamp>/
# Cron (daily 02:30 host time):
#   30 2 * * * cd /opt/singlestack && make backup >> backups/backup.log 2>&1
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_env
require_cmd docker sha256sum

base="${BACKUP_DIR:-./backups}"
[[ "$base" = /* ]] || base="$ROOT_DIR/${base#./}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$base/$stamp"
work="$dest.partial"

for c in ss-postgres ss-chatwoot ss-listmonk; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]] || die "$c is not running"
done

umask 077
mkdir -p "$work"
trap 'rm -rf "$work"' ERR

log "postgres globals (roles)"
docker exec ss-postgres pg_dumpall -U postgres --globals-only > "$work/globals.sql"

for db in chatwoot listmonk; do
  log "postgres: $db"
  docker exec ss-postgres pg_dump -U postgres -Fc --dbname "$db" > "$work/$db.dump"
done

log "files: chatwoot storage"
docker exec ss-chatwoot tar -czf - -C /app/storage . > "$work/chatwoot-storage.tgz"
log "files: listmonk uploads"
docker exec ss-listmonk tar -czf - -C /listmonk/uploads . > "$work/listmonk-uploads.tgz"

cp "$ENV_FILE" "$work/env"
{
  echo "created_utc=$stamp"
  echo "chatwoot_image=$CHATWOOT_IMAGE"
  echo "listmonk_image=$LISTMONK_IMAGE"
  echo "postgres_image=$POSTGRES_IMAGE"
} > "$work/MANIFEST"
(cd "$work" && sha256sum -- * > SHA256SUMS)

mv "$work" "$dest"
trap - ERR
ok "backup: $dest ($(du -sh "$dest" | cut -f1))"

keep="${BACKUP_KEEP_DAYS:-14}"
pruned="$(find "$base" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -mtime +"$keep" -print -exec rm -rf {} + | wc -l)"
(( pruned > 0 )) && ok "pruned $pruned backup(s) older than $keep days"
warn "backups contain .env secrets — sync off-host to encrypted storage (e.g. rclone crypt / restic)"
