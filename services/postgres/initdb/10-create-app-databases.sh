#!/usr/bin/env bash
# Runs once, on an empty data directory (postgres image entrypoint).
# One role + one database per app; each app owns only its own database.
set -euo pipefail

: "${CHATWOOT_DB_PASSWORD:?}"
: "${LISTMONK_DB_PASSWORD:?}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v cw_pw="$CHATWOOT_DB_PASSWORD" \
  -v lm_pw="$LISTMONK_DB_PASSWORD" <<'SQL'
CREATE ROLE chatwoot LOGIN PASSWORD :'cw_pw';
CREATE ROLE listmonk LOGIN PASSWORD :'lm_pw';
CREATE DATABASE chatwoot OWNER chatwoot;
CREATE DATABASE listmonk OWNER listmonk;
REVOKE ALL ON DATABASE chatwoot FROM PUBLIC;
REVOKE ALL ON DATABASE listmonk FROM PUBLIC;
SQL

# Chatwoot's schema enables these. Some (vector, pg_stat_statements) need a
# superuser, so create them here; the app's `enable_extension` is then a no-op.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname chatwoot <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
ALTER SCHEMA public OWNER TO chatwoot;
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname listmonk <<'SQL'
ALTER SCHEMA public OWNER TO listmonk;
SQL
