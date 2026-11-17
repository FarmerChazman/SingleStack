# singlestack documentation

This guide takes you from an empty server and a set of domains to a working
support desk and newsletter system that you can operate. Read the chapters in
order the first time. After that, each chapter works as a reference.

| # | Chapter | You will… | Time |
|---|---|---|---|
| 1 | [Concepts](01-concepts.md) | understand MX, SPF, DKIM, DMARC, envelopes, and how mail flows through this stack | 20 min read |
| 2 | [Prerequisites and planning](02-prerequisites.md) | gather accounts, pick hostnames and addresses, fill in the planning worksheet | 15 min |
| 3 | [Cloudflare Email Routing, for all your domains](03-cloudflare-email-routing.md) | enable inbound mail on every domain, by hand or with `make email-routing-apply` | 15 min per domain, or 5 min total scripted |
| 4 | [Brevo, for outbound mail](04-brevo.md) | authenticate every sending domain and create SMTP keys | 10 min per domain, plus DNS wait |
| 5 | [The inbound-mail Worker](05-inbound-worker.md) | deploy the Cloudflare Worker that hands mail to Chatwoot | 10 min |
| 6 | [Server installation](06-server-install.md) | install Docker, configure `.env`, start the stack | 20 min |
| 7 | [Publishing the web UIs](07-publishing.md) | expose `support.` and `lists.` through Cloudflare Tunnel (or nginx) | 10 min |
| 8 | [First run: Chatwoot and Listmonk](08-first-run.md) | create admins and inboxes, connect SMTP, send the first test mails | 30 min |
| 9 | [Operations](09-operations.md) | back up, restore, upgrade, monitor and troubleshoot | reference |
| 10 | [Sending from your own apps](10-app-smtp.md) | point your other applications at Brevo the right way | 5 min per app |
| — | [Architecture and decisions](architecture.md) | the reasons behind every design choice | reference |

## Dependency order

The order matters because later steps verify earlier ones:

```
 (2) plan ──► (3) Email Routing ──► (5) Worker ──┐
         └──► (4) Brevo ─────────────────────────┤
 (6) server ──► (7) publish ──────────────────────┴──► (8) first run ──► (9) operate
```

Chapters 3–5 (Cloudflare and Brevo) and 6–7 (server) are independent of each
other, so you can work on both tracks at once while DNS propagates. Chapter 8
needs both tracks finished.

## Conventions used in this guide

- **Placeholder domains.** `example.com` is your primary domain. `example.org`
  and `example.net` are extra brands. `you@your-mailbox.example` is a personal
  mailbox you already read, such as Gmail. Always substitute your own values.
- **Hostnames.** `support.example.com` is Chatwoot and `lists.example.com` is
  Listmonk.
- **Where commands run.** Blocks prefixed `$` run on the **server**, inside the
  repository directory (`/opt/singlestack`). Blocks marked *(laptop)* run on
  your workstation.
- **Navigation.** Dashboard paths are written as **Menu → Submenu → Button**.
  Cloudflare reorganises its dashboard from time to time. If a label has
  moved, use the dashboard search (`/` key) and type the last element of the
  path.
- **Callouts.** **⚠** marks something that can lose mail or data if done
  wrong. **✓ Checkpoint** marks a test you should pass before you continue.

## Getting help

When something misbehaves, start with `make doctor`. Then check the
troubleshooting tables at the end of chapters 3, 5 and 9. To report a bug,
open an issue that includes the output of `make doctor` and
`make logs s=<service>`, with secrets redacted.
