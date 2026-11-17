# 1. Concepts

This chapter explains the moving parts so that the configuration steps that
follow make sense. If you already work with mail DNS daily, skim §1.6 and §1.7,
which are specific to this stack.

## 1.1 The two directions of mail

Mail has two independent directions, and this stack uses a different provider
for each:

| Direction | Question it answers | Controlled by | Provider here |
|---|---|---|---|
| **Inbound** | When someone mails `support@example.com`, which server accepts it? | the domain's **MX** records | Cloudflare Email Routing |
| **Outbound** | When we send *from* `support@example.com`, which servers may do so, and how can receivers verify it? | **SPF**, **DKIM** and **DMARC** records | Brevo |

Because the directions are independent, you can change one without touching
the other. If you move outbound sending from Brevo to another relay, inbound
routing doesn't change.

## 1.2 MX: where inbound mail goes

An MX (Mail eXchanger) record names the host that accepts mail for a domain,
along with a priority (lower is tried first):

```
example.com.  MX  13  route1.mx.cloudflare.net.
example.com.  MX  86  route2.mx.cloudflare.net.
example.com.  MX  24  route3.mx.cloudflare.net.
```

A sending server looks up these records, connects to the host on TCP port 25,
and delivers the message. A domain has exactly **one** inbound provider: if
the MX records point at Cloudflare, Gmail or Microsoft can't also receive
mail for the same addresses. That's why Cloudflare refuses to enable Email
Routing while other MX records exist (chapter 3, §4.3).

**Your server never receives SMTP.** Cloudflare's MX hosts accept the mail,
and a Worker then forwards it over HTTPS. Port 25 can stay closed. Many
residential and cloud providers block it anyway.

## 1.3 Envelope and headers

Every message has two sets of addresses, and confusing them is the most common
source of routing bugs:

| | Envelope (SMTP `MAIL FROM` / `RCPT TO`) | Headers (`From:`, `To:`, `Cc:`) |
|---|---|---|
| Purpose | delivery: where the message goes *now* | display: what people see |
| Can differ from headers? | Yes: BCC, mailing lists, forwarding | — |
| Used by | MX routing, SPF, bounces | mail clients, DMARC alignment |
| In the Worker | `message.from`, `message.to` | `message.headers` |

Example: you send a message to a mailing list, and the list delivers it to
`support@example.com`. The `To:` header says `list@lists.example.net`, but the
envelope recipient is `support@example.com`. Cloudflare routes on the
**envelope**. Chatwoot, by default, looks at the **headers**. The Worker
bridges the gap by adding an `X-Original-To: <envelope recipient>` header,
which Chatwoot also reads (chapter 5, §5.1).

## 1.4 SPF, DKIM and DMARC: proving outbound mail is genuine

Receivers such as Gmail and Outlook decide whether to trust a message by
checking three DNS-published policies:

**SPF** (Sender Policy Framework) is a TXT record at the domain that lists
which servers may send with this domain in the *envelope* sender:

```
example.com.  TXT  "v=spf1 include:_spf.mx.cloudflare.net include:spf.brevo.com ~all"
```

- There must be **exactly one** `v=spf1` record per name. Two records cause a
  `permerror`, and receivers treat that as having no SPF at all.
- Evaluating the record may trigger at most **10 DNS lookups** in total. Each
  `include:` costs at least one. Too many includes cause a `permerror` too.
- `~all` (softfail) means "anything not listed is suspicious". `-all` (fail)
  means "reject it". `~all` is the safer default while you're setting up.
- Email Routing needs `include:_spf.mx.cloudflare.net` because Cloudflare
  *forwards* mail, and forwarded mail is re-sent from Cloudflare's servers.

**DKIM** (DomainKeys Identified Mail) is a cryptographic signature added to
each outgoing message. The public key lives in DNS at a *selector* name such
as `brevo1._domainkey.example.com`. Several DKIM keys can coexist because each
uses its own selector. Brevo uses `brevo1` and `brevo2`, and Cloudflare Email
Routing uses `cf2024-1`. A DKIM signature survives forwarding; SPF does not.

**DMARC** is a policy at `_dmarc.example.com` that ties the two together. A
message passes DMARC when SPF or DKIM passes **and** the domain that passed
*aligns* with the visible `From:` domain. The policy tells receivers what to
do on failure:

```
_dmarc.example.com.  TXT  "v=DMARC1; p=none; rua=mailto:dmarc@example.com"
```

| `p=` | Effect | When to use |
|---|---|---|
| `none` | monitor only; aggregate reports go to `rua` | first 2–4 weeks |
| `quarantine` | failures go to spam | once reports show only your legitimate senders |
| `reject` | failures are refused | mature setups |

With Brevo, DMARC normally passes through **DKIM alignment**: Brevo signs
with `d=example.com` using your `brevo1/brevo2` keys.

## 1.5 Forwarding and why destination addresses must be verified

When Email Routing *forwards* a message to `you@gmail.com`, Cloudflare sends
it again from its own servers. To stop people from using Cloudflare to spam
arbitrary inboxes, every forward target must be a **verified destination
address**. Cloudflare emails it a link, and the rule stays inactive until you
click it. Rules whose action is a **Worker** don't need a destination address.

## 1.6 How a support email flows through this stack

```
customer@gmail.com
   │  SMTP to MX of example.com
   ▼
Cloudflare Email Routing ── rule: support@example.com → Worker
   │
   ▼
Worker "singlestack-inbound-mail"
   │  1. reads the raw message (RFC 822 / MIME)
   │  2. prepends  X-Original-To: support@example.com
   │  3. POST https://support.example.com/rails/action_mailbox/relay/inbound_emails
   │       Content-Type: message/rfc822
   │       Authorization: Basic actionmailbox:<CHATWOOT_INBOUND_PASSWORD>
   │  4. on failure: retries, then forwards to FALLBACK_FORWARD
   ▼
Cloudflare Tunnel ──► server localhost:3001 ──► Chatwoot (Rails Action Mailbox)
   │  matches To/Cc/X-Original-To against Email inboxes → new conversation
   ▼
Agent replies in Chatwoot
   │  SMTP (587, STARTTLS) to smtp-relay.brevo.com, signed with DKIM d=example.com
   │  From: support@example.com   Reply-To: reply+<conversation-uuid>@example.com
   ▼
customer@gmail.com receives the reply, hits "Reply"
   │  → reply+<uuid>@example.com
   ▼
Cloudflare: subaddressing makes reply+<uuid>@ match the rule reply@example.com → Worker
   ▼
Chatwoot sees reply+<uuid>, finds the conversation by UUID → same thread
```

## 1.7 Conversation continuity and subaddressing

Chatwoot threads replies by giving every conversation a unique Reply-To
address, `reply+<conversation-uuid>@<MAILER_INBOUND_EMAIL_DOMAIN>`. That's an
unbounded number of addresses, and Cloudflare can't hold a rule for each one.
Two Cloudflare features could cover them:

- A **catch-all** rule only exists on the apex domain, and you probably want
  the catch-all for something else, such as dropping spam or forwarding
  typos.
- **Subaddressing** (RFC 5233 "plus addressing") makes `user+anything@domain`
  match the rule for `user@domain`, while keeping the full address visible to
  the Worker.

This stack uses subaddressing. You create one literal rule, `reply@example.com
→ Worker`, and turn subaddressing on for the zone. A side effect, usually a
welcome one: `support+billing@example.com` now also reaches the `support@`
rule.

## 1.8 Glossary

| Term | Meaning |
|---|---|
| Zone | A domain added to Cloudflare, such as `example.com`. Email Routing is configured per zone. |
| Apex | The bare domain, `example.com`, as opposed to `support.example.com` |
| Rule / custom address | A mapping from one address to an action: forward, Worker or drop |
| Catch-all | The rule for any address on the apex that no other rule matches |
| Destination address | A verified mailbox that rules may forward to; shared across the account |
| Email Worker | A Cloudflare Worker with an `email()` handler, invoked by a routing rule |
| Relay ingress | Rails Action Mailbox's HTTP endpoint that accepts raw messages: `/rails/action_mailbox/relay/inbound_emails` |
| SMTP key | A Brevo credential used as the SMTP password. Create one per sending application. |
| Tunnel | Cloudflare Tunnel (`cloudflared`): outbound-only connection that publishes local services without opening ports |
