# Architecture and decisions

## Design constraints

singlestack is built for a common small-operator situation:

- **One shared Docker host** that already runs other projects. Ports 80 and
  443 often belong to an existing proxy, and many common ports are taken.
- **Inbound port 25 isn't available.** Residential and many cloud networks
  block it, and running a public MTA is a job of its own.
- **Cloudflare already terminates TLS**, typically through Cloudflare Tunnel.
- **Several brands or domains**, with modest volume: thousands of mails a
  month, not millions.

## Components

| Container | Image | Networks | Published | Role |
|---|---|---|---|---|
| `ss-postgres` | `pgvector/pgvector:pg16` | backend | — | one instance; databases `chatwoot` and `listmonk`, each with its own owner role |
| `ss-redis` | `redis:7-alpine` | backend | — | Chatwoot's Sidekiq queues and ActionCable |
| `ss-chatwoot-migrate` | `chatwoot/chatwoot` | default, backend | — | one-shot `db:chatwoot_prepare`; gates the two below |
| `ss-chatwoot` | `chatwoot/chatwoot` | default, backend, edge | `127.0.0.1:3001` | Rails web, API, ActionCable, Action Mailbox ingress |
| `ss-chatwoot-worker` | `chatwoot/chatwoot` | default, backend | — | Sidekiq: outgoing mail, inbound mail processing, jobs |
| `ss-listmonk` | `listmonk/listmonk` | default, backend, edge | `127.0.0.1:3002` | campaigns, subscriber pages, admin |

Outside the host:

| Piece | Where | Role |
|---|---|---|
| Cloudflare Email Routing | each zone | MX for all domains; rules → Worker / forward / drop |
| `singlestack-inbound-mail` | Cloudflare Workers | raw message → Chatwoot relay ingress, with retries and fallback |
| Cloudflare Tunnel | `cloudflared` on the host | `support.` → `:3001`, `lists.` → `:3002` |
| Brevo | SaaS | SMTP relay for all outbound mail; DKIM signing for your domains |

## Networks

- **`backend`** is `internal: true`. Postgres and Redis can't reach the
  internet, and only stack containers can reach them.
- **`default`** gives the app containers egress: Brevo SMTP, webhooks,
  image pulls.
- **`edge`** is external and shared. It's only needed when a proxy runs *in a
  container* (chapter 7 §7.3). `make up` creates it, so it costs nothing when
  unused.
- **Host binds are loopback only.** Nothing is reachable from the LAN or the
  public IP.

## Decisions

### D1: No self-hosted mail server
Without inbound port 25, a self-hosted MTA could only be a sending hop in
front of a relay, plus mailboxes nobody reads. Cloudflare receives and Brevo
sends. Each is free at this scale, has good reputation, and is operated by
someone else. *Trade-off:* there are no hosted mailboxes. Forward personal
addresses to an existing mailbox.

### D2: No bundled reverse proxy or TLS
A second proxy would fight the host's existing one for 80 and 443. The stack
binds loopback ports, and the tunnel publishes them. A shared Docker network
covers the case where the proxy itself is a container, since a container
can't reach the host's `127.0.0.1`.

### D3: One Postgres instance, one database and role per app
Chatwoot requires pgvector, and Listmonk runs on it unchanged. Separate
owner roles mean neither app can read the other's data, and backups and
restores happen per database. *Cost:* the two apps share Postgres major
upgrades, which are rare and planned (chapter 9 §9.3).

### D4: Inbound through an Email Worker and Rails' relay ingress
The alternatives were IMAP polling (it needs a real mailbox somewhere,
stored credentials, and adds polling delay) or a third-party inbound parse
service. The relay ingress accepts raw RFC 822 over HTTPS with one shared
secret. Delivery takes seconds, and the Worker adds retries and a fallback
mailbox, so a Chatwoot outage doesn't lose mail.

### D5: Conversation continuity via subaddressing
Chatwoot gives every conversation a `reply+<uuid>@domain` Reply-To address.
Cloudflare catch-alls exist only on apex domains (and you may want the
catch-all for something else), and subdomains can't be added through the
API. One literal `reply@` rule plus zone subaddressing covers every UUID
exactly, and the script automates it.

### D6: Migrations as a gating one-shot service
`chatwoot-migrate` must exit 0 before web and worker start
(`service_completed_successfully`). A failed migration blocks the deploy
instead of running new code against an old schema. Listmonk does the same
inside its own command (`--install --idempotent && --upgrade`).

### D7: Pinned images, explicit upgrades
Tags live in `.env`, and `latest` is never used. `make upgrade` always backs
up first. Rollback means a restore, because migrations are one-way.

### D8: One Brevo SMTP key per consumer
Chatwoot, Listmonk and each app get separate keys. One leaked key can be
revoked without touching the rest, and Brevo's logs attribute every message
to its key.

### D9: Host-cron backups, `.env` included
`pg_dump -Fc` per database is a consistent snapshot without stopping
anything. File volumes are tarred from the running containers. `.env` is
included because `SECRET_KEY_BASE` is needed to decrypt Chatwoot's encrypted
columns. A cron line has fewer moving parts than a backup sidecar.
Checksums are verified on restore, and only complete backups are kept
(written as `.partial`, then renamed).

### D10: Email Routing as code, additive only
`cf-email-routing.sh` converges rules from a text file but never deletes
anything it didn't create. It refuses to enable zones whose MX records
belong to another provider. Personal configuration stays out of git.

### D11: Hardening defaults
Every secret is required (`${VAR:?}`), and `.env` is mode 600 and parsed
without being executed. `no-new-privileges`, per-container memory limits and
capped log files are set throughout. The Worker has no public HTTP route
(`workers_dev = false`). Cloudflare Access is recommended for the Listmonk
admin.

## Deliberately not included

- **Listmonk bounce processing from Brevo webhooks.** Brevo already suppresses
  hard bounces. An adapter (Brevo webhook → Listmonk `/webhooks/bounce`) would
  fit in the Worker if list hygiene needs it.
- **S3 storage for attachments.** Local volumes are fine at this scale.
  Switch Chatwoot's `ACTIVE_STORAGE_SERVICE` when needed.
- **High availability.** Single host by design. Recovery is restore-based
  (chapter 9 §9.2.4).
