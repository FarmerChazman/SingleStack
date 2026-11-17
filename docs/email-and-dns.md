# Email: DNS, Brevo and the inbound worker

Replace `yourdomain.com` throughout. Repeat sections 1 and 3 for each extra
brand domain.

> **Status for farmanalyser.com (17 Nov 2026 DNS snapshot):** the Brevo
> `brevo-code`, both DKIM CNAMEs (`brevo1/2._domainkey`) and `_dmarc` are
> already in place. There are **no MX records yet**, so Email Routing isn't
> enabled. Enabling it in section 3 adds the MX and SPF records. Other brand
> domains (safetrucktrips.com, freefarmmap.com, …) need sections 1 and 3 each.

## 1. Brevo (sending)

1. Go to **Brevo → Senders, Domains & Dedicated IPs → Domains → Add a domain**.
2. Add **exactly** the DNS records Brevo shows (a `brevo-code` TXT record, DKIM
   records, and its DMARC suggestion) in Cloudflare DNS, set to **DNS only**.
   Then click *Authenticate*.
3. If Brevo asks for SPF, merge it into one SPF record with Cloudflare's
   (a domain must have only one):
   `v=spf1 include:_spf.mx.cloudflare.net include:spf.brevo.com ~all`
4. Go to **SMTP & API → SMTP** and create a key for each sender:
   `chatwoot`, `listmonk`, then one per app ([app-smtp.md](app-smtp.md)).
   Put the Chatwoot login and key in `.env` (`CHATWOOT_SMTP_USER` /
   `CHATWOOT_SMTP_KEY`).
5. Start DMARC in monitoring mode: `_dmarc` TXT
   `v=DMARC1; p=none; rua=mailto:dmarc@yourdomain.com`. After two clean weeks
   of reports, move to `p=quarantine`.

> The free plan caps daily sends (it was 300 a day when this was written;
> check your plan). Set Listmonk's sliding-window limit to match; see
> [operations.md](operations.md#listmonk).

## 2. Deploy the inbound worker

```bash
cd workers/inbound-mail
npm ci
npx wrangler login
$EDITOR wrangler.toml          # CHATWOOT_INBOUND_URL, FALLBACK_FORWARD
npx wrangler secret put CHATWOOT_INBOUND_PASSWORD   # paste the value from .env
npm run check && npx wrangler deploy
```

- `CHATWOOT_INBOUND_URL` is
  `https://support.yourdomain.com/rails/action_mailbox/relay/inbound_emails`.
- `FALLBACK_FORWARD` should be a mailbox you own, for example a Gmail address.
  Verify it first under **Email Routing → Destination addresses**. Mail lands
  there whenever Chatwoot is unreachable, tagged with
  `X-Singlestack-Relay: failed; <reason>`.

## 3. Cloudflare Email Routing rules

First, if Email Routing isn't enabled on the zone yet, go to **Email → Email
Routing → Get started / Enable** and accept the MX and SPF records it offers.
Then, in **Routing rules** for `yourdomain.com`:

| Custom address | Action | Destination |
|---|---|---|
| `support@yourdomain.com` | Send to a Worker | `singlestack-inbound-mail` |

Keep any existing rules (personal forwards, other aliases) as they are.

**Conversation continuity domain (`CHATWOOT_INBOUND_DOMAIN`, default
`in.yourdomain.com`).** Chatwoot sets `Reply-To: reply+<uuid>@in.yourdomain.com`,
so it needs a catch-all:

1. Go to **Email Routing → Settings → Subdomains** and add `in`. Cloudflare
   creates the subdomain's MX and SPF records.
2. For the subdomain, set **catch-all → Send to a Worker →
   `singlestack-inbound-mail`**.

Why a subdomain: a catch-all on the apex would swallow every address. And
`support.` can't hold MX records, because it's a proxied hostname or tunnel
CNAME.

Other brands use the same worker. Add a `support@otherbrand.com` → worker
rule in that zone, plus a matching Chatwoot inbox. One continuity domain
serves all brands.

## 4. Chatwoot inbox

Go to **Settings → Inboxes → Add inbox → Email → Other providers** and enter
`support@yourdomain.com`. The forwarding address Chatwoot displays isn't
needed, because the worker relays `support@` directly. Then go to **Settings →
Account settings** and turn on conversation continuity by email, if your
version shows that toggle.

## 5. Verify end to end

```bash
make doctor                                # relay ingress answers 401 to a wrong password
npx wrangler tail --format pretty          # in workers/inbound-mail, while you send a test mail
```

Send a message from an outside account to `support@`. Within seconds it
should show up as a conversation, and the tail should log
`"event":"relayed","status":204`. Reply from Chatwoot, then reply again from
the outside account. The second reply should land in the **same**
conversation.
