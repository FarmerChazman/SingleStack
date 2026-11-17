# Operations

## First run

### Chatwoot
1. Open `https://support.yourdomain.com`. On a fresh install it shows the
   onboarding screen. Create the super-admin account and the first workspace.
2. Go to **Profile → Security** and turn on 2FA.
3. Create the Email inbox ([email-and-dns.md §4](email-and-dns.md#4-chatwoot-inbox)).
   Optionally add a **Website** inbox for live chat and paste its widget
   snippet into your sites.
4. Sign-ups stay off (`CHATWOOT_ENABLE_SIGNUP=false`). Invite agents from
   **Settings → Agents**.

### Listmonk
Log in at `https://lists.yourdomain.com/admin` as `LISTMONK_ADMIN_USER` /
`LISTMONK_ADMIN_PASSWORD` (from `.env`), then:

| Setting | Value |
|---|---|
| General → Root URL | `https://lists.yourdomain.com` |
| General → Default "from" email | `Your Brand <news@yourdomain.com>` (domain verified in Brevo) |
| SMTP → Host / Port | `smtp-relay.brevo.com` / `587` |
| SMTP → Auth / TLS | `LOGIN` / `STARTTLS` |
| SMTP → Username / Password | Brevo login / the **listmonk** SMTP key |
| SMTP → Max connections | `5` |
| Performance → Sliding window | on, duration `24h`, rate ≈ your Brevo daily cap minus headroom (e.g. `280` on the free plan) |
| Media → Upload path | `/listmonk/uploads` |
| Privacy → Individual tracking | your call; off is friendlier for GDPR |

Click **Send test e-mail** on the SMTP page before you send any campaign.
Change the admin password after the first login.

## Backups

```bash
make backup                         # -> backups/<UTC stamp>/{chatwoot,listmonk}.dump, *.tgz, env, SHA256SUMS
crontab -e                          # daily at 02:30:
30 2 * * * cd /opt/singlestack && make backup >> backups/backup.log 2>&1
```

Retention is `BACKUP_KEEP_DAYS` (14 by default). Backups include `.env`
secrets. Copy them off the host to encrypted storage (restic or rclone crypt).
**A backup you haven't restored is a hope, not a backup.** Test a restore on
a scratch host each quarter:

```bash
make restore FROM=backups/20261117T023000Z   # verifies checksums, asks you to type the project name
```

## Upgrades

1. Read the release notes:
   [Chatwoot](https://github.com/chatwoot/chatwoot/releases),
   [Listmonk](https://github.com/knadh/listmonk/releases). Skipping minor
   versions is normally fine for both, but check the notes for required
   intermediate steps.
2. Change the tag in `.env` (`CHATWOOT_IMAGE` / `LISTMONK_IMAGE`).
3. Run `make upgrade`. It backs up, pulls, runs migrations (the migrate job
   gates the app), waits until healthy, then runs `doctor`.
4. **Rollback.** Chatwoot migrations aren't reversible. Revert the tag, then
   run `make restore FROM=<the backup make upgrade just made>`.

While the upgrade runs, Chatwoot is briefly down. Inbound mail goes to
`FALLBACK_FORWARD` meanwhile, if you set it.

## Logs and debugging

```bash
make logs s=chatwoot-web       # also: chatwoot-worker, chatwoot-migrate, listmonk, postgres, redis
make doctor
make psql db=chatwoot
make chatwoot-console          # Rails console
docker stats --no-stream $(docker ps -q --filter name=^ss-)
```

| Symptom | Likely cause | Check |
|---|---|---|
| `make up` says migrations failed | DB unreachable or a bad image tag | `make logs s=chatwoot-migrate` |
| 502 / 1033 on `support.` | tunnel route missing or wrong port, or container down | tunnel routes → `http://localhost:3001`; `make ps`; `curl 127.0.0.1:3001/health` |
| Live updates don't arrive | websocket headers missing in the proxy | browser devtools → `/cable` should return 101 |
| Inbound mail doesn't arrive | worker URL or secret wrong | `npx wrangler tail`: `relay_failed … HTTP 401` means a wrong password |
| Mail arrives but no conversation | no inbox with that address | create the Email inbox for that exact address |
| Replies start new conversations | continuity domain not routed | `in.` catch-all → worker ([email-and-dns.md §3](email-and-dns.md#3-cloudflare-email-routing-rules)) |
| Outbound mail stuck | Brevo key wrong, or sender domain not verified | `make logs s=chatwoot-worker \| grep -i smtp`; Brevo → Logs |
| Campaign stops partway | Brevo daily cap reached | Listmonk sliding window; Brevo plan |
