# Architecture and decisions

## Constraints that shaped this stack

- **It shares a host with about 20 containers.** `farmanalyser-nginx` already
  holds `:80`, and `5173`, `8000`, `8088`, `8090` and `9000–9001` are taken.
- **Inbound port 25 is closed**, so the host can't receive SMTP directly.
- **TLS already ends at Cloudflare.** A dashboard-managed tunnel
  (`vmwebt1650`) runs cloudflared on the host and reaches services on
  `localhost`. Nothing publishes `:443`.
- **Volume is about 5,000 emails a month**, across several brands.

## Data flow

**Inbound support mail.** A sender's MTA delivers to Cloudflare's MX. An Email
Routing rule (`support@brand`, or the `in.` subdomain catch-all) passes the
message to the `inbound-mail` worker. The worker POSTs the raw MIME to
`https://support.<domain>/rails/action_mailbox/relay/inbound_emails` with
`actionmailbox:<CHATWOOT_INBOUND_PASSWORD>`. Chatwoot matches the
`To`/`Cc`/`X-Original-To` address to an Email inbox, or matches
`reply+<uuid>@in.<domain>` to an existing conversation.

**Outbound support mail.** Chatwoot sends through its global SMTP setting
(Brevo, port 587, STARTTLS). The From address is the inbox's address, and the
Reply-To is `reply+<uuid>@in.<domain>`, so customer replies return to the same
thread.

**Campaigns.** Listmonk sends through Brevo with its own SMTP key. Public pages
(subscribe, unsubscribe, tracking links, archive) are served on `lists.<domain>`.

**App mail.** Each app talks to Brevo directly with its own key. It never
passes through this stack.

## Decisions

### D1: No self-hosted mail server (BillionMail dropped)
With port 25 closed, a mail server would only be a sending hop in front of
Brevo, plus mailboxes nobody reads. Cloudflare handles inbound and Brevo
handles outbound. *What we give up:* mailboxes on our own server, and per-app
SMTP logins issued locally. Brevo keys replace those logins (see D7).

### D2: No bundled reverse proxy or TLS
The host already has an edge: Cloudflare Tunnel, with cloudflared on the host.
A second proxy would only fight `farmanalyser-nginx` for `:80`. The stack
binds to `127.0.0.1:3001` and `:3002`, and two tunnel routes publish them.
Nothing is reachable from the LAN or the public IP.

The stack also joins an external Docker network, `edge`, for one case: if a
proxy *container* ever fronts it, that container can't use the host's
`127.0.0.1`, so it reaches the stack by container name instead. `make up`
creates the network, so it costs nothing when it isn't used.

### D3: One Postgres instance, one database and role per app
`pgvector/pgvector:pg16` is the image Chatwoot requires, and Listmonk runs on
it unchanged. Each app owns only its own database, so a bug or a compromised
app can't read the other's data. Backups and restores stay per database. *Cost:*
both apps upgrade Postgres majors together, which is rare and planned.

### D4: Inbound through a worker and Rails' relay ingress, not IMAP polling
IMAP would need a real mailbox somewhere, credentials stored in Chatwoot, and
a polling delay. With the relay ingress, delivery is near-instant, there's no
mailbox to maintain, and the only secret is the shared ingress password. The
worker retries 5xx and network errors. If Chatwoot is down, it forwards to
`FALLBACK_FORWARD`, so mail isn't lost during an outage or upgrade.

### D5: Migrations as a one-shot service that gates the app
`chatwoot-migrate` runs `db:chatwoot_prepare` on every `up`. That loads the
schema on the first run and migrates afterwards. Web and worker start only
when it exits 0 (`service_completed_successfully`). A failed migration stops
the deploy instead of booting half-migrated code. Listmonk does the same thing
inside its own command (`--install --idempotent && --upgrade`).

### D6: Pinned images, explicit upgrades
Tags live in `.env`. An upgrade means changing the tag, reading the release
notes, and running `make upgrade`, which backs up first. `latest` is never
used, so a restart never changes the version by surprise.

### D7: One Brevo SMTP key per consumer
Chatwoot, Listmonk and each app get separate keys. You can revoke one leaked
key without touching the rest, and Brevo's logs show who sent what.

### D8: Backups run from host cron, not from a sidecar container
`make backup` takes `pg_dump -Fc` of each database (a consistent MVCC
snapshot), tarballs of both file volumes, and the `.env` file. The `.env` copy
matters: without `SECRET_KEY_BASE`, Chatwoot can't decrypt the credentials it
stores. A cron line has fewer moving parts than a long-running backup
container.

### D9: Hardening defaults
Postgres and Redis sit on an `internal` network with no route out. Every
secret is required (`${VAR:?}`). `no-new-privileges` is on, logs are capped
at 10 MB × 3 per container, each container has a memory limit, and `.env` is
mode 600.

## Not built (yet), on purpose

- **Listmonk bounce ingestion from Brevo.** Brevo already suppresses hard
  bounces and complaints on its side. A small webhook adapter (Brevo →
  `/webhooks/bounce`) can be added to the worker if list hygiene needs it.
- **Offsite backups.** Pipe `backups/` to restic or rclone-crypt. Which one
  depends on your storage, so it isn't scripted here.
- **S3 storage for Chatwoot attachments.** Local disk is fine at this volume.
  Switch with `ACTIVE_STORAGE_SERVICE` when needed.
