# Changelog

## 3.1.0 — 2026-11-17

- **Docs:** a numbered ten-chapter guide (`docs/01`–`docs/10`) covering
  concepts, planning, Email Routing, Brevo, the Worker, server install,
  publishing, first run, operations and app SMTP. It replaces the four short
  docs.
- **New `scripts/cf-email-routing.sh`** with `make email-routing-plan`,
  `make email-routing-apply` and `make email-routing-status`. It manages
  Cloudflare Email Routing for any number of domains from
  `deploy/cloudflare/email-routing.conf`. It's idempotent and additive, and it
  refuses zones that use another mail provider. Tested against a mock API in
  CI.
- **Fix:** conversation continuity now uses a `reply@<domain>` rule plus
  subaddressing. The earlier advice to use a catch-all on a subdomain
  couldn't work, because Cloudflare offers catch-alls only on apex domains.
  `CHATWOOT_INBOUND_DOMAIN` now defaults to the apex.
- **Generalised for public use:** removed host-specific names, so the tunnel
  setup and the nginx alternative are documented generically.
- `make test` now runs the Worker unit tests and the routing-script
  integration test.

## 3.0.0 — 2026-11-17 (lean rewrite)

Replaces `singlestack-bm-2.0.0`.

- **Removed:** BillionMail (the mail server) and the bundled Caddy (TLS and proxy).
- **Inbound mail:** a Cloudflare Email Worker sends messages to Chatwoot's Action
  Mailbox relay ingress, with retries and a fallback forward.
- **Outbound mail:** goes through Brevo, with one SMTP key per sender.
- **Added Listmonk** for campaigns. It shares a Postgres instance with
  Chatwoot, each app with its own role and database.
- **No public ports:** loopback-only binds on 3001 and 3002, published through the
  existing Cloudflare Tunnel. An optional `edge` network serves proxy containers.
- **Migrations:** a one-shot migrate job gates Chatwoot web and worker.
- **Scripts:** `preflight`, `doctor`, checksummed `backup` and `restore`, and
  `upgrade`.
- **CI:** shellcheck, a compose render check, and worker typecheck and tests.
