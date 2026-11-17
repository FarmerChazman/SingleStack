# 5. The inbound-mail Worker

`workers/inbound-mail` is a small Cloudflare Email Worker. Email Routing
invokes it for `support@…` and `reply@…`, and it hands each message to
Chatwoot over HTTPS. It's the only custom code in the mail path, so this
chapter describes it fully.

## 5.1 What it does

For every message it receives, the Worker:

1. **Rejects** messages over 25 MiB with a permanent error. Cloudflare can't
   accept larger ones anyway.
2. **Reads** the raw RFC 822 message (headers and MIME body, byte for byte).
3. **Prepends** `X-Original-To: <envelope recipient>`. Chatwoot's
   `EmailChannelFinder` checks `To`, `Cc` and `X-Original-To`, so mail that
   reached you by BCC, an alias or a list still lands in the right inbox. CR
   and LF are stripped from the address, so it can't inject headers.
4. **POSTs** the bytes to Chatwoot's Rails Action Mailbox relay ingress:

   ```
   POST https://support.example.com/rails/action_mailbox/relay/inbound_emails
   Content-Type: message/rfc822
   Authorization: Basic base64("actionmailbox:" + CHATWOOT_INBOUND_PASSWORD)
   ```

   Chatwoot answers `204 No Content` once the message is queued.
5. **Retries** network errors and HTTP 5xx: 3 attempts, 15-second timeout
   each, with 0.75 s and 1.5 s backoff. HTTP 4xx isn't retried, because it
   means misconfiguration (401 is a wrong password, 404 a wrong URL, 415 a
   wrong content type).
6. **On final failure,** forwards the original message to `FALLBACK_FORWARD`
   with the header `X-Singlestack-Relay: failed; <reason>`. With no fallback
   set, it throws, and Cloudflare reports the failure to the sending server.
7. **Logs** one JSON line per message (`relayed`, `relay_failed`,
   `forwarded_fallback`, `misconfigured`) with sender, recipient and size.
   Message bodies are never logged.

Source layout:

```
workers/inbound-mail/
  src/index.ts        email() handler: size check, relay, fallback
  src/relay.ts        pure logic (body building, auth, retry policy), unit-tested
  test/relay.test.ts  node:test tests (no Cloudflare account needed)
  wrangler.toml       name, vars, observability
```

## 5.2 Prerequisites

- Node.js 22.6 or newer, and npm, on any machine (laptop or server).
- `CHATWOOT_INBOUND_PASSWORD` from the server's `.env` (created by
  `make init`, chapter 6).
- A **verified** destination address for the fallback (chapter 3, §5).
- Chatwoot doesn't need to be running yet. Deploying the Worker first is
  fine, and mail goes to the fallback until Chatwoot is up.

## 5.3 Configure

Edit `workers/inbound-mail/wrangler.toml`:

```toml
name = "singlestack-inbound-mail"        # the name you select in routing rules
main = "src/index.ts"
compatibility_date = "2026-09-01"
workers_dev = false                      # no public *.workers.dev URL: it's email-only

[vars]
CHATWOOT_INBOUND_URL = "https://support.example.com/rails/action_mailbox/relay/inbound_emails"
FALLBACK_FORWARD = "you@your-mailbox.example"

[observability]
enabled = true                           # logs in the dashboard (Workers → Logs)
```

If you rename the Worker, use the same name in the routing rules and in
`deploy/cloudflare/email-routing.conf`.

## 5.4 Deploy

```bash
cd workers/inbound-mail
npm ci                                   # exact versions from package-lock.json
npm run check                            # typecheck + unit tests
npx wrangler login                       # opens a browser; or export CLOUDFLARE_API_TOKEN for CI
npx wrangler secret put CHATWOOT_INBOUND_PASSWORD
#   paste the value of CHATWOOT_INBOUND_PASSWORD from the server's .env
npx wrangler deploy
```

`wrangler deploy` prints the bindings, which should show the two vars. Secrets
are encrypted at rest and never printed. To rotate the password: change it in
`.env`, run `make up` (Chatwoot restarts with the new value), run `wrangler
secret put` again, and test.

**Headless deploy** (CI or a server without a browser): create an API token
from the **Edit Cloudflare Workers** template, then:

```bash
export CLOUDFLARE_API_TOKEN=…  CLOUDFLARE_ACCOUNT_ID=…
npx wrangler deploy
```

## 5.5 Connect it to Email Routing

Create the Worker rules (chapter 3, §6.2), or list them in
`deploy/cloudflare/email-routing.conf` and run `make email-routing-apply`
(chapter 3, §8).

## 5.6 Test and observe

```bash
cd workers/inbound-mail
npx wrangler tail --format pretty        # live log stream; leave it running
```

Send a mail from an outside account to `support@example.com`, then match
what you see:

| Log line | Meaning |
|---|---|
| `"event":"relayed","status":204,"attempts":1` | delivered to Chatwoot |
| `"event":"relay_failed","reason":"HTTP 401"` | wrong `CHATWOOT_INBOUND_PASSWORD` in the Worker or in `.env` |
| `"reason":"HTTP 404"` | wrong URL, or Chatwoot isn't the service behind the hostname |
| `"reason":"HTTP 415"` | something between the Worker and Chatwoot rewrote the `Content-Type` |
| `"reason":"HTTP 413"` | a proxy in front of Chatwoot limits the body size. Allow ≥ 30 MB (nginx: `client_max_body_size`). |
| `"reason":"HTTP 502"` / `530` / `TimeoutError` | tunnel or container down. The fallback should then fire. |
| `"event":"forwarded_fallback"` | the message went to your fallback mailbox |
| `"event":"misconfigured"` | a var or the secret is missing; redeploy |

Test the ingress directly from the server, without the Worker:

```bash
$ source <(grep ^CHATWOOT_INBOUND_PASSWORD= .env)
$ printf 'From: test@example.net\r\nTo: support@example.com\r\nSubject: ingress test\r\nMessage-ID: <t1@example.net>\r\n\r\nhello\r\n' |
  curl -sS -o /dev/null -w '%{http_code}\n' -u "actionmailbox:$CHATWOOT_INBOUND_PASSWORD" \
    -H 'Content-Type: message/rfc822' --data-binary @- \
    http://127.0.0.1:3001/rails/action_mailbox/relay/inbound_emails
# 204, and after a few seconds a conversation "ingress test" in the support@ inbox
```

`make doctor` checks that the endpoint exists and rejects a wrong password
with 401.

## 5.7 Failure modes and guarantees

| Situation | What happens to the email |
|---|---|
| Chatwoot down briefly (upgrade, restart) | retried; then delivered to `FALLBACK_FORWARD` |
| Chatwoot down and no fallback configured | Worker throws; Cloudflare signals failure to the sender's server, which may retry or bounce, depending on the sender |
| Wrong secret | 401, no retry, fallback. Fix it quickly: every message takes this path. |
| Message > 25 MiB | rejected at SMTP by Cloudflare; the sender gets a bounce |
| Chatwoot accepted it (204) but has no matching inbox | stored by Rails, then "bounced" internally. No conversation appears. Create the inbox (chapter 8). |
| Worker free-plan CPU or memory limit hit on very large messages | Cloudflare logs an exception; consider the Workers Paid plan if this recurs |

**Duplicates:** if Chatwoot processed a message but the HTTP response was
lost on the way back, the retry delivers it again. The design accepts a rare
duplicate message in exchange for never silently losing one.

## 5.8 Development

```bash
cd workers/inbound-mail
npm test                                 # node --test with type stripping
npm run typecheck                        # tsc against @cloudflare/workers-types
npx wrangler deploy --dry-run --outdir dist   # bundle without deploying
```

Next: [6. Server installation](06-server-install.md)
