# 9. Operations

## 9.1 Daily commands

| Command | Use |
|---|---|
| `make ps` | container status |
| `make doctor` | full health check (exits non-zero on failure, so it works in cron and monitoring) |
| `make logs s=chatwoot-web` | follow one service. Others: `chatwoot-worker`, `chatwoot-migrate`, `listmonk`, `postgres`, `redis` |
| `make restart` | restart the app containers, not the databases |
| `make down` / `make up` | stop / start; volumes are kept |
| `make psql db=chatwoot` | SQL shell (superuser) |
| `make chatwoot-console` | Rails console, for advanced fixes |

## 9.2 Backups

### 9.2.1 What a backup contains

`make backup` writes `backups/<UTC-timestamp>/`:

| File | Content | Method |
|---|---|---|
| `globals.sql` | roles and their password hashes | `pg_dumpall --globals-only` |
| `chatwoot.dump` | Chatwoot database | `pg_dump -Fc`, a consistent MVCC snapshot taken while running |
| `listmonk.dump` | Listmonk database | `pg_dump -Fc` |
| `chatwoot-storage.tgz` | attachments, avatars (`/app/storage`) | tar from the running container |
| `listmonk-uploads.tgz` | campaign media | tar from the running container |
| `env` | a copy of `.env` | **contains every secret**, including `SECRET_KEY_BASE` |
| `MANIFEST` | timestamp and image versions | |
| `SHA256SUMS` | checksums of all of the above | verified on restore |

The backup is written to `<stamp>.partial` and renamed only on success, so a
directory without `.partial` is always complete. Backups older than
`BACKUP_KEEP_DAYS` are pruned at the end of each run. Redis isn't backed up:
it holds only queues and caches, which rebuild themselves.

**Why `.env` is included:** Chatwoot encrypts some stored values (for
example, integration credentials and 2FA secrets) with keys derived from
`SECRET_KEY_BASE`. A database restored with a different key loses them, and
logs everyone out.

### 9.2.2 Schedule it

```bash
crontab -e
# daily at 02:30 server time
30 2 * * * cd /opt/singlestack && make backup >> backups/backup.log 2>&1
```

### 9.2.3 Copy it off the host

A backup on the same disk doesn't protect against disk loss or a compromised
server. Encrypt it and copy it elsewhere, for example with **restic** to any
S3-compatible bucket:

```bash
export RESTIC_REPOSITORY=s3:https://<endpoint>/<bucket>/singlestack
export RESTIC_PASSWORD_FILE=/root/.restic-pass AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
restic init                                   # once
restic backup /opt/singlestack/backups --tag singlestack
restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
```

Add these lines after `make backup` in the cron job. Store the restic
password outside the server too: without it, the backups are useless.

### 9.2.4 Restore

```bash
$ make restore FROM=backups/20261117T023000Z
```

The restore runs in this order:

1. It verifies every checksum and aborts on any mismatch.
2. It warns if the backup's `SECRET_KEY_BASE` differs from the current
   `.env`. To restore onto a fresh server, copy `backups/<stamp>/env` to
   `.env` **before** restoring.
3. It asks you to type the project name.
4. It stops the app containers, keeping Postgres and Redis running.
5. For each database: it terminates connections, runs `DROP DATABASE`,
   recreates the database with the right owner, and runs `pg_restore` as the
   superuser (so extensions and ownership come back exactly).
6. It empties and refills both file volumes.
7. It starts everything. Migrations run automatically if the restored data is
   older than the image.

**Disaster recovery on a new host:** chapter 6 §6.1–6.2, copy the backup
directory over, `cp backups/<stamp>/env .env`, `make up` (this creates empty
volumes), then `make restore FROM=…`, then chapter 7 (tunnel). The Worker and
Cloudflare need no changes as long as the hostnames stay the same.

**Practise a restore every quarter** on a scratch VM. A backup you've never
restored is a hope, not a backup.

## 9.3 Upgrades

Both applications release often. The stack pins exact versions in `.env`, so
nothing changes until you decide.

1. **Read the release notes** for every version between yours and the target:
   [Chatwoot releases](https://github.com/chatwoot/chatwoot/releases),
   [Listmonk releases](https://github.com/knadh/listmonk/releases). Look for
   *breaking*, *migration*, *Postgres* and *Redis*. Some Chatwoot releases
   require intermediate steps or newer Postgres or Redis versions.
2. **Change the tag** in `.env` (`CHATWOOT_IMAGE`, `LISTMONK_IMAGE`). Upgrade
   one application at a time.
3. **Run:**

   ```bash
   $ make upgrade      # backup → pull → migrate (gated) → wait healthy → doctor
   ```

4. **Smoke test:** run the ch. 8 §8.1.5 round trip, and send a Listmonk test
   email.

**Rollback:** Chatwoot and Listmonk migrations aren't reversible. Put the old
tag back in `.env` and run `make restore FROM=<the backup make upgrade just
created>`. Mail that arrived in between went to Chatwoot, which you'll lose,
or to `FALLBACK_FORWARD` if Chatwoot was down.

**Postgres major upgrades** (e.g. pg16 → pg17) can't be done by changing the
image. Take a backup, `make down`, remove the `singlestack_postgres_data`
volume, change `POSTGRES_IMAGE`, run `make up` (fresh init), then
`make restore FROM=…`. Rehearse it on a copy first.

**This repository:** `git pull` (or check out a newer tag), read
`CHANGELOG.md`, compare `.env.example` with your `.env` for new variables,
then `make up`.

## 9.4 Monitoring

| What | How |
|---|---|
| Stack health | cron `*/5 * * * * cd /opt/singlestack && make -s doctor >/dev/null \|\| <notify>`; `doctor` exits 1 on failure |
| External availability | an uptime service polling `https://support.example.com/health` and `https://lists.example.com/health` |
| Inbound mail | Cloudflare **Email Routing → Activity log**; Worker logs (**Workers → singlestack-inbound-mail → Logs**) for `relay_failed` |
| Outbound mail | **Brevo → Transactional → Logs / Statistics**; hard-bounce and complaint rates |
| Fallback mailbox | anything tagged `X-Singlestack-Relay: failed` means Chatwoot missed mail; investigate, then forward it to support |
| Disk | `df -h`, `docker system df`; attachments and backups grow |
| Resources | `docker stats --no-stream $(docker ps -q --filter name=^ss-)` |

Chatwoot also has a built-in **Super Admin → Instance health** page.

## 9.5 Secret rotation

| Secret | Procedure |
|---|---|
| Brevo SMTP key (Chatwoot) | create a new key → update `.env` → `make up` → test → revoke the old key |
| Brevo SMTP key (Listmonk) | create → update in Listmonk **Settings → SMTP** → test → revoke the old key |
| `CHATWOOT_INBOUND_PASSWORD` | new value in `.env` → `make up` → `npx wrangler secret put CHATWOOT_INBOUND_PASSWORD` → test. Mail in between goes to the fallback. |
| `REDIS_PASSWORD` | change in `.env` → `make down && make up` |
| DB role passwords | `make psql` → `ALTER ROLE chatwoot PASSWORD '…';` → update `.env` → `make up` |
| `CHATWOOT_SECRET_KEY_BASE` | **avoid**: logs everyone out and breaks encrypted columns. Only after a compromise. |
| Cloudflare API tokens | short-lived by design (ch. 3 §8.1); delete after use |

## 9.6 Troubleshooting

| Symptom | Likely cause | Look at |
|---|---|---|
| `make up`: "chatwoot migrations failed" | DB unreachable, bad image tag, a release needing intermediate steps | `make logs s=chatwoot-migrate` |
| `make up` times out waiting for health | first boot still compiling or caching, or out of memory | `make logs s=chatwoot-web`, `dmesg \| grep -i oom` |
| Public URL returns 502 / 1033 | tunnel route wrong, `cloudflared` down, or container down | ch. 7; `systemctl status cloudflared`; `curl 127.0.0.1:3001/health` |
| Chatwoot UI loads but nothing updates live | `/cable` websocket blocked | browser devtools → Network → `cable` should return 101 |
| Inbound mail missing | routing rule, Worker, secret | ch. 3 §10, ch. 5 §5.6 |
| Customer replies open new conversations | subaddressing off, or no `reply@` rule | ch. 3 §6.1 |
| Outbound mail not sent | Brevo key, sender domain, daily limit | `make logs s=chatwoot-worker \| grep -i smtp`; ch. 4 §4.6 |
| Listmonk campaign paused | sliding window reached | intended; ch. 8 §8.2.4 |
| Links in campaigns point to localhost | Root URL not set | ch. 8 §8.2.2 |
| Disk filling up | backups, attachments, Docker images | `du -sh backups`; `docker image prune` |
| After restore, everyone is logged out and integrations broken | `SECRET_KEY_BASE` mismatch | restore `.env` from the backup's `env` |

## 9.7 Decommissioning

1. Take a final `make backup` and copy it off the host.
2. Remove the Worker rules (Email Routing) or point them elsewhere, and delete
   the Worker.
3. Remove the tunnel routes for `support.` and `lists.`.
4. `make down`, then `docker volume rm singlestack_postgres_data
   singlestack_redis_data singlestack_chatwoot_storage
   singlestack_listmonk_uploads`. **⚠ Irreversible.**
5. Revoke the Brevo SMTP keys.
