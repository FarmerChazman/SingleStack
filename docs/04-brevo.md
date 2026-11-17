# 4. Brevo for outbound mail

Every message this stack sends goes through Brevo's SMTP relay: Chatwoot's
replies and notifications, Listmonk's campaigns, and, optionally, your own
apps (chapter 10). This chapter authenticates each sending domain so that
Gmail, Outlook and others trust the mail, and creates one credential per
sender.

## 4.1 Create and activate the account

1. Sign up at <https://www.brevo.com>. Use an address you'll keep; it becomes
   the account owner.
2. Complete the company profile. Brevo reviews new accounts before allowing
   sends, and an incomplete profile is the most common reason for delay.
3. Expect a short approval period. Until approval, SMTP may accept
   credentials but not deliver.

The free plan allows **300 emails a day**, shared by every key on the
account: transactional and marketing together. At roughly 5,000 mails a
month in an even spread, that fits. A single 2,000-recipient campaign does
not. Plan for this in Listmonk (chapter 8, §8.2.4) or buy a paid plan.

## 4.2 Authenticate each sending domain

Do this for **every** domain that appears in a `From:` address:
`support@example.com`, `news@example.com`, `no-reply@example.org`, and so on.

1. **Brevo → Settings (gear) → Senders, Domains & Dedicated IPs → Domains →
   Add a domain.**
2. Enter `example.com`. When asked how to authenticate, choose **manual /
   "Authenticate the domain yourself"**. Brevo's automatic Cloudflare
   integration also works, but the manual path shows you exactly what is
   added.
3. Brevo shows a set of records. Today they typically are:

| Type | Name | Content (example) | Purpose |
|---|---|---|---|
| TXT | `@` | `brevo-code:0123456789abcdef…` | proves you own the domain |
| CNAME | `brevo1._domainkey` | `b1.example-com.dkim.brevo.com` | DKIM key 1 (Brevo rotates keys behind the CNAME) |
| CNAME | `brevo2._domainkey` | `b2.example-com.dkim.brevo.com` | DKIM key 2 |
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:rua@dmarc.brevo.com` | DMARC policy, if you have none yet |

4. In Cloudflare, go to **DNS → Records → Add record** for each one, using
   **exactly** the values Brevo shows (the table above is only an example):
   - **Proxy status: DNS only (grey cloud).** A proxied CNAME breaks DKIM:
     receivers would see Cloudflare's IPs instead of the target.
   - **TTL:** Auto.
   - The **Name** field takes just the host part. Cloudflare appends the
     domain.
5. Back in Brevo, select **Authenticate this email domain**. Every row should
   show a green tick. If one doesn't, wait 5–10 minutes and retry.

✓ **Checkpoint** *(laptop)*:

```bash
dig +short TXT example.com | grep brevo-code
dig +short CNAME brevo1._domainkey.example.com
dig +short TXT _dmarc.example.com
```

### 4.2.1 SPF and Brevo

Brevo's current domain authentication relies on **DKIM** for DMARC
alignment, so it no longer asks for an SPF include on most accounts. If your
Brevo screen *does* list `include:spf.brevo.com`, merge it into the single
SPF record together with Cloudflare's include:

```
v=spf1 include:_spf.mx.cloudflare.net include:spf.brevo.com ~all
```

Never create a second `v=spf1` record. See chapter 3, §4.4.

### 4.2.2 DMARC: one record, and reports you can read

There may be only one `_dmarc` record per domain. If Brevo offers one and you
already have one, keep yours and make sure it has a `rua=` address.

A practical progression:

| Week | Record | Action |
|---|---|---|
| 0 | `v=DMARC1; p=none; rua=mailto:dmarc@example.com` | collect reports. `dmarc@` is forwarded to you (chapter 3, §7.1). |
| 2–4 | read the reports | every legitimate source (Brevo, any other senders) should show `dkim=pass` and aligned |
| 4+ | `v=DMARC1; p=quarantine; pct=100; rua=…` | failures go to spam |
| later | `p=reject` | optional, strictest |

Aggregate reports are XML attachments. A free DMARC report viewer makes them
readable. You can also keep `rua=mailto:rua@dmarc.brevo.com`, which shows a
summary inside Brevo. Multiple `rua` addresses are comma-separated.

## 4.3 Register senders

**Senders, Domains & Dedicated IPs → Senders → Add a sender** for each From
address you'll use, for example `Support <support@example.com>` and
`Example News <news@example.com>`. On an authenticated domain, Brevo
verifies them without a confirmation mail. Messages from unregistered
senders may be rejected or rewritten.

## 4.4 Create one SMTP key per sender application

**Settings → SMTP & API → SMTP tab:**

- Note the **SMTP server** (`smtp-relay.brevo.com`), the **port** (587), and
  the **Login**. The login is shown on this page. Depending on the account's
  age, it's either your account email or a generated `…@smtp-brevo.com`
  address. Use exactly what the page shows.
- **Generate a new SMTP key** for each consumer, named after it:

| Key name | Used by | Goes into |
|---|---|---|
| `singlestack-chatwoot` | Chatwoot | `.env` → `CHATWOOT_SMTP_USER` (the Login) and `CHATWOOT_SMTP_KEY` |
| `singlestack-listmonk` | Listmonk | Listmonk UI → Settings → SMTP (chapter 8) |
| `app-<name>-prod` | each of your apps | that app's configuration (chapter 10) |

Copy each key as soon as it's shown. Brevo won't show it again; if you lose
one, revoke it and generate a new one.

Why one key per consumer: if a key leaks, you revoke it without breaking
anything else. You also get per-sender statistics.

**Ports:** 587 with STARTTLS is the default and works almost everywhere. Use
465 (implicit TLS) only if a library requires it. Port 25 isn't used.

## 4.5 Verify sending

Test from the server, before Chatwoot is involved:

```bash
$ curl -v --url 'smtp://smtp-relay.brevo.com:587' --ssl-reqd \
    --user 'LOGIN:SMTP_KEY' \
    --mail-from 'support@example.com' --mail-rcpt 'you@your-mailbox.example' \
    --upload-file - <<'EOF'
From: Support <support@example.com>
To: you@your-mailbox.example
Subject: singlestack SMTP test

If you can read this, Brevo accepts our credentials.
EOF
```

In the received message, use **Show original** in Gmail (or the equivalent in
your client) and check:

```
SPF:   PASS (or neutral)     DKIM: 'PASS' with domain example.com     DMARC: 'PASS'
```

**Brevo → Transactional → Logs** shows every message with its status
(delivered, deferred, soft or hard bounce, blocked).

## 4.6 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `535 Authentication failed` | Wrong login (the page's Login, not your password) or a revoked key | recopy the Login; generate a new key |
| Accepted, but nothing arrives; log says *blocked* | account not yet approved, or sender not registered | finish the profile (§4.1); add the sender (§4.3) |
| DKIM `fail` or `none` | CNAME is proxied (orange cloud) or mistyped | set **DNS only**; compare character by character |
| DMARC `fail` with DKIM pass | DKIM signed with `d=brevo.com` (domain not authenticated) | finish §4.2 for that From domain |
| Gmail shows "via brevo.com" | same as above | same as above |
| `421` / temporary deferrals during a campaign | daily limit or rate limit reached | Listmonk sliding window (chapter 8); upgrade the plan |
| Mails land in spam despite passes | new domain reputation, content, missing unsubscribe | warm up gradually; Listmonk adds `List-Unsubscribe` automatically |

Next: [5. The inbound-mail Worker](05-inbound-worker.md)
