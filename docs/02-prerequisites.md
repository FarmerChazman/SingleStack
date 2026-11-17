# 2. Prerequisites and planning

## 2.1 Accounts

| Account | Plan needed | Used for |
|---|---|---|
| **Cloudflare** | Free plan is enough | DNS, Email Routing, Workers, Tunnel, optional Access |
| **Brevo** | Free plan (300 emails a day) is enough to start | outbound SMTP for Chatwoot, Listmonk and your apps |
| **GitHub** (optional) | — | cloning this repository, CI |

**Every domain must use Cloudflare as its authoritative DNS.** The registrar
can be anyone, but the nameservers must be Cloudflare's. Email Routing isn't
available for zones on partial (CNAME) setup. To check *(laptop)*:

```bash
dig +short NS example.com
# expect two names like  ada.ns.cloudflare.com.  bob.ns.cloudflare.com.
```

## 2.2 Server

| Resource | Minimum | Notes |
|---|---|---|
| OS | any 64-bit Linux that runs Docker Engine 24+ | Ubuntu 22.04/24.04 LTS and Debian 12 are tested by the community |
| CPU | 2 vCPU | Chatwoot's web and worker processes are the main consumers |
| RAM | 4 GiB free | the stack uses about 2.5–3.5 GiB under light load |
| Disk | 10 GiB free for Docker | plus backups; attachments grow over time |
| Network out | TCP 443 (Cloudflare Tunnel, image pulls) and TCP 587 to `smtp-relay.brevo.com` | |
| Network in | **nothing** | no open ports are required, not even 25, 80 or 443 |

The stack is built to share a host with other projects. It publishes only to
`127.0.0.1` and uses its own Docker networks and container names (`ss-*`).

## 2.3 Tools

| Where | Tool | Why |
|---|---|---|
| server | `docker` + `docker compose` v2 plugin, `make`, `git`, `curl`, `openssl` | running the stack |
| server | `cloudflared` | publishing (chapter 7); skip if you use another proxy |
| laptop or server | Node.js 22+ and `npm` | deploying the Worker with Wrangler (chapter 5) |
| laptop or server | `jq`, `curl` | the multi-domain Email Routing script (chapter 3, §8) |
| laptop | `dig` (in `dnsutils` or `bind-utils`) | verifying DNS |

## 2.4 Decide names before you touch DNS

Fill in this worksheet. Every later chapter refers to these values.

| Item | Example | Yours |
|---|---|---|
| Primary domain (`DOMAIN`) | `example.com` | |
| Chatwoot hostname (`SUPPORT_HOST`) | `support.example.com` | |
| Listmonk hostname (`LISTS_HOST`) | `lists.example.com` | |
| Support address(es), one per brand | `support@example.com`, `support@example.org` | |
| Continuity domain (`CHATWOOT_INBOUND_DOMAIN`) | `example.com` → replies use `reply+<uuid>@example.com` | |
| Chatwoot system sender (`CHATWOOT_MAILER_SENDER`) | `Support <support@example.com>` | |
| Newsletter From address | `news@example.com` | |
| Fallback mailbox for the Worker (`FALLBACK_FORWARD`) | `you@your-mailbox.example` | |
| Personal forwards (optional) | `hello@`, `dmarc@` → `you@your-mailbox.example` | |
| What happens to unknown addresses (catch-all) | drop, or forward | |

Rules of thumb:

- **Keep `support.` and `lists.` free of MX records.** They're web hostnames
  served by the tunnel. Mail addresses live on the apex (`@example.com`).
- **Use the apex as the continuity domain.** A subdomain also works, but it
  has to be enabled by hand in the dashboard (no API exists for it, chapter 3
  §7.3), and catch-all rules aren't available on subdomains.
- **Reserve `reply@<continuity domain>`** for Chatwoot. Don't use that
  address for anything else.
- **Pick a real fallback mailbox.** When Chatwoot is down for an upgrade,
  support mail goes there instead of bouncing.

## 2.5 Where each secret lives

| Secret | Created by | Stored in |
|---|---|---|
| Postgres, Redis, Chatwoot and Listmonk passwords, `SECRET_KEY_BASE` | `make init` | server `.env` (mode 600) |
| `CHATWOOT_INBOUND_PASSWORD` | `make init` | server `.env` **and** Worker secret (chapter 5) |
| Brevo SMTP keys | you, in Brevo | server `.env` (Chatwoot), Listmonk UI, each app's config |
| Cloudflare API token | you, in Cloudflare | your shell only, while running the routing script; never committed |
| Cloudflare Tunnel token | Cloudflare | the `cloudflared` service on the server |

**⚠** Nothing secret is ever committed to git. `.gitignore` excludes `.env`,
`backups/` and your real `deploy/cloudflare/email-routing.conf`.
