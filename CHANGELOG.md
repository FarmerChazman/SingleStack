# Changelog

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
