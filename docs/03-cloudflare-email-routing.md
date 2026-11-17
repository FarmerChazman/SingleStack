# 3. Cloudflare Email Routing for all your domains

This chapter enables inbound mail on **every** domain you own and wires the
addresses this stack needs: `support@`, `reply@` with subaddressing, an
optional catch-all, and any personal forwards. There are two routes to the
same result:

- **By hand in the dashboard** (§4–§7). Best for one or two domains, and the
  best way to learn what is happening.
- **Scripted for all domains at once** (§8). One config file and
  `make email-routing-apply`. It's idempotent and safe to re-run, and it
  never deletes rules it doesn't manage.

Even if you plan to use the script, read §4.3 (domains that already receive
mail) and §6 (the rules this stack depends on).

---

## 1. What Email Routing does and does not do

| Does | Does not |
|---|---|
| Accept mail for your domains on Cloudflare's MX servers | Host mailboxes. There's no IMAP, POP or webmail. |
| Forward each address to a verified mailbox | Send mail *from* your domain. That's Brevo's job (chapter 4). |
| Hand messages to a Worker (our route into Chatwoot) | Coexist with another inbound provider on the same domain |
| Drop or forward unknown addresses (catch-all) | Accept messages larger than 25 MiB |
| Match `user+tag@` to the `user@` rule (subaddressing) | Offer catch-all rules on subdomains |

It's free on every Cloudflare plan.

## 2. Requirements and limits

- The domain is a **full** Cloudflare zone, using Cloudflare nameservers
  (chapter 2, §2.1).
- You have **Administrator** (or Super Administrator) access to the account,
  or an API token with the permissions in §8.1.

| Limit | Value |
|---|---|
| Routing rules per domain | 200 |
| Verified destination addresses per account | 200 (shared by all domains) |
| Inbound message size | 25 MiB; larger messages are rejected at SMTP time |
| Domains per zone with Email Routing/Sending (apex + subdomains) | 30 |
| Actions per rule | 1 (one destination, one Worker, or drop) |

## 3. Plan your rules

Write the plan down before you click anything. This is the plan the rest of
the chapter implements. Copy it and adapt it to your domains:

| Zone | Address | Action | Target | Why |
|---|---|---|---|---|
| example.com | `support@example.com` | Worker | `singlestack-inbound-mail` | support desk |
| example.com | `reply@example.com` | Worker | `singlestack-inbound-mail` | Chatwoot conversation continuity (needs subaddressing) |
| example.com | `hello@example.com` | Forward | `you@your-mailbox.example` | personal contact |
| example.com | `dmarc@example.com` | Forward | `you@your-mailbox.example` | DMARC aggregate reports (chapter 4) |
| example.com | catch-all | Drop | — | ignore guesses and spam |
| example.org | `support@example.org` | Worker | `singlestack-inbound-mail` | second brand, same Chatwoot |
| example.org | catch-all | Forward | `you@your-mailbox.example` | |
| example.net | catch-all | Forward | `you@your-mailbox.example` | forwarding-only domain |

> **The Worker must exist before you can choose it as a rule target.** If you
> haven't deployed it yet, do chapter 5 first, or create the Worker rules
> afterwards. Forward rules can be created at any time.

---

## 4. Enable Email Routing on a domain (dashboard)

### 4.1 Check the domain's current mail setup

In **DNS → Records** for the zone, filter by type **MX**. Then *(laptop)*:

```bash
dig +short MX example.com
dig +short TXT example.com | grep -i spf
```

| What you see | Go to |
|---|---|
| No MX records | §4.2. This is the simple case. |
| MX already `routeN.mx.cloudflare.net` | Already enabled. Go to §5. |
| MX of another provider (Google Workspace, Microsoft 365, Zoho, your host…) | **Stop** and read §4.3 first. |

### 4.2 Onboard the domain

1. Log in at <https://dash.cloudflare.com> and select your **account**.
2. Go to **Compute → Email Service → Email Routing**. (On older dashboards,
   select the **zone** first, then **Email → Email Routing**.)
3. Select **Onboard Domain** (older UI: **Get started** / **Enable Email
   Routing**).
4. Choose the domain. Cloudflare shows the DNS records it will add. Review
   them; the next section explains each one.
5. Select **Done** (older UI: **Add records and enable**).

Cloudflare adds these records to the zone and **locks** them, so they can't
be edited under **DNS → Records** while Email Routing manages them:

| Type | Name | Content | Purpose |
|---|---|---|---|
| MX | `@` | `route1.mx.cloudflare.net` | inbound mail; priorities are assigned automatically |
| MX | `@` | `route2.mx.cloudflare.net` | redundancy |
| MX | `@` | `route3.mx.cloudflare.net` | redundancy |
| TXT | `@` | `v=spf1 include:_spf.mx.cloudflare.net ~all` | authorises Cloudflare to *forward*. Added only if the zone has no SPF record yet (§4.4). |
| TXT | `cf2024-1._domainkey` | `v=DKIM1; …` (Cloudflare's public key) | Cloudflare signs forwarded mail. Doesn't conflict with Brevo's `brevo1/brevo2` selectors. |

**"Locked" and "Unlocked" both mean the record is correct.** The label only
says whether Email Routing manages it. You can unlock root-domain records
under **Email Routing → Settings → DNS records → Unlock**, for example while
migrating to another provider.

✓ **Checkpoint.** **Email Routing → Settings** shows status **Enabled** /
**Ready**, and *(laptop)* `dig +short MX example.com` lists three
`routeN.mx.cloudflare.net` hosts. Propagation inside Cloudflare usually takes
under a minute. External resolvers can take up to the old records' TTL.

### 4.3 Domains that already receive mail elsewhere

**⚠ Enabling Email Routing replaces your current inbound provider for the
whole domain.** You can't keep Google Workspace mailboxes for `alice@` and
send `support@` to Cloudflare on the same domain. A domain has one set of MX
records. Onboarding fails with **error 2008, "Non-Cloudflare MX records
exist"** for exactly this reason. The routing script (§8) refuses such zones
for the same reason.

Pick one option:

**Option A: keep the existing provider and use a different domain or
subdomain for support.** For example, keep Workspace on `example.com` and
run support on `example.org`, or on a subdomain such as `help.example.com`
(§7.3). This is the safest option.

**Option B: let your current provider forward `support@` into this stack.**
Leave the MX records alone. In Google Workspace or Microsoft 365, add a
forward from `support@example.com` to an address on a domain that *does* use
Email Routing, such as `support@example.org`. Chatwoot also matches the
original `To:` header, so create the Chatwoot inbox for
`support@example.com`.

**Option C: migrate the whole domain to Email Routing.** Do this only if you
no longer need hosted mailboxes, because everything becomes forwards. The
order below avoids losing mail:

1. Lower the TTL of the existing MX records to 300 seconds, a day in advance.
2. Add and **verify** every destination address you'll need (§5). Verification
   works before onboarding.
3. Write down every address that currently receives mail, including aliases
   and groups. Each one needs a rule. Mail to an address with no rule and no
   catch-all is rejected with *"Address does not exist"*, and senders don't
   retry.
4. In **DNS → Records**, delete the old provider's MX records. Keep its SPF
   `include:` and DKIM records if you still *send* through it.
5. **Immediately** onboard the domain (§4.2).
6. **Immediately** create the rules and catch-all (§6, §7).
7. Send test mail from an outside account to each important address.
8. Keep the old provider account for a week in case of late deliveries from
   caches.

During steps 4–6, some senders may see a temporary failure and retry later.
Resolvers that cached the missing records can take up to about 30 minutes
to retry.

### 4.4 Existing SPF record (for example, from Brevo)

A domain must have **exactly one** `v=spf1` TXT record. If the domain already
has one, Cloudflare doesn't add a second. You must merge the Cloudflare
`include:` into the existing record:

```
before:  v=spf1 include:spf.brevo.com ~all
after:   v=spf1 include:_spf.mx.cloudflare.net include:spf.brevo.com ~all
```

Edit it in **DNS → Records** (type TXT, name `@`). Then confirm *(laptop)*:

```bash
dig +short TXT example.com | grep spf      # exactly ONE line
```

Each `include:` costs DNS lookups, and the limit is 10. Cloudflare plus Brevo
plus one more provider is fine. Five providers may not be. Remove includes
for services you no longer use.

### 4.5 Repeat for every domain

Do §4.1–§4.4 for each zone in your plan. A domain that only forwards (like
`example.net` in §3) needs nothing else from this repository.

---

## 5. Destination addresses (for forward rules)

Destination addresses belong to the **account**, not to a zone. Verify each
one once and every domain can use it.

1. **Compute → Email Service → Email Routing → Destination addresses** (older
   UI: **Email Routing → Destination addresses** inside any zone).
2. **Add destination address**, enter `you@your-mailbox.example`, then
   **Save**.
3. Open that mailbox and click **Verify email address** in Cloudflare's
   message. Check the spam folder too.
4. The address changes from *Pending* to *Verified*. Rules pointing to a
   pending address stay inactive.

**⚠** Deleting a destination address disables **every** rule that uses it,
across all domains.

Rules whose action is a Worker don't use destination addresses. The Worker's
own fallback (`FALLBACK_FORWARD`, chapter 5) **does** need a verified
destination address, because the Worker calls `message.forward()`.

---

## 6. The rules this stack depends on

### 6.1 Turn on subaddressing (once per zone)

**Email Routing → (select the domain) → Settings → Subaddressing → Enable.**

From now on `reply+6bdc3f4d-…@example.com` matches the rule for
`reply@example.com`. The full address, including `+…`, still reaches the
Worker and Chatwoot. A rule for an exact sub-address
(`reply+something@`) would take precedence, so don't create one.

**Why this is mandatory.** For Email inboxes, Chatwoot always sets
`Reply-To: reply+<conversation-uuid>@<CHATWOOT_INBOUND_DOMAIN>`. Without
subaddressing, those replies have no matching rule. They hit the catch-all,
which may drop them, or bounce with "Address does not exist". Customers'
replies would never reach the conversation.

### 6.2 Create the Worker rules

Deploy the Worker first (chapter 5). Then, for each support address:

1. **Email Routing → (domain) → Routing rules → Create address** (older UI:
   **Custom addresses → Create address**).
2. **Custom address / Email pattern:** `support`. The domain is fixed.
3. **Action:** **Send to a Worker**.
4. **Destination:** `singlestack-inbound-mail`.
5. **Save.** Leave the rule **Active**.

Repeat with `reply` for the continuity domain (normally the apex of your
primary domain), and with `support` for every other brand domain.

### 6.3 Multiple brands

One Worker and one Chatwoot instance serve every brand:

- **Each brand domain** needs its `support@brand → Worker` rule (§6.2), plus
  subaddressing if that brand's Chatwoot *account* uses its own continuity
  domain.
- **In Chatwoot**, create one Email inbox per support address (chapter 8).
- **Continuity domain.** By default every brand's replies use
  `reply+<uuid>@<CHATWOOT_INBOUND_DOMAIN>`. To keep brands visibly separate,
  create a separate Chatwoot **account** per brand, set its **Account
  settings → Domain** to the brand's domain, and add a `reply@<brand>`
  Worker rule with subaddressing on that zone.

---

## 7. Other rules

### 7.1 Personal forwards

**Create address → `hello` → Send to an email → `you@your-mailbox.example`.**
The target must be verified (§5). It's a good idea to create `dmarc@` this
way, so that DMARC aggregate reports from chapter 4 reach you.

### 7.2 Catch-all

**Routing rules → Catch-all address → Edit**, enable it, choose an action,
then **Save**.

| Action | Effect | Choose when |
|---|---|---|
| **Drop** | unknown addresses silently vanish | you publish only a few addresses; best against spam |
| **Send to an email** | everything else goes to your mailbox | small domains where typos matter (`supprot@`) |
| **Send to a Worker** | the Worker decides | advanced; the inbound Worker would push **all** unknown mail into Chatwoot as conversations, which is rarely what you want |

With the catch-all **disabled**, unknown addresses are rejected at SMTP time
and the sender gets a bounce. That's honest, and it reveals which addresses
exist. Catch-alls exist only on the apex domain.

### 7.3 Subdomains (dashboard only)

To receive mail at `@help.example.com`:

1. **Email Routing → (apex domain) → Settings → Subdomains**, enter `help`,
   then submit. Cloudflare adds the subdomain's MX, SPF and DKIM records.
2. Create literal rules such as `support@help.example.com`. **Catch-all isn't
   available on subdomains.**

There's no API for adding subdomains, so the script in §8 only warns when a
configured address uses a subdomain that isn't enabled yet. Never enable mail
on a hostname that's already a tunnel or proxied web record (`support.`,
`lists.`): MX records can't coexist with a CNAME on the same name.

### 7.4 Disabling or deleting a rule

Toggle a rule to **Disabled** to pause it. Deleting is permanent. A disabled
address with no catch-all bounces. With a catch-all, it falls through to the
catch-all.

---

## 8. Scripted setup for all domains

`scripts/cf-email-routing.sh` turns a plain-text desired state into API
calls, for any number of zones. For each zone it:

1. finds the zone, and **refuses** it if the MX records belong to another
   provider (§4.3);
2. enables Email Routing if it's off, which adds and locks MX, SPF and DKIM;
3. checks SPF: exactly one record, including Cloudflare. If not, it prints the
   merged record for you to apply;
4. sets subaddressing (on by default);
5. creates missing destination addresses, which triggers verification emails;
6. creates rules that are missing, updates rules that have drifted, and sets
   the catch-all;
7. **lists unmanaged rules but never deletes them.**

### 8.1 Create a scoped API token

**My Profile → API Tokens → Create Token → Create Custom Token:**

| Scope | Permission | Level |
|---|---|---|
| Zone | Zone | Read |
| Zone | DNS | Read |
| Zone | Zone Settings | Edit |
| Zone | Email Routing Rules | Edit |
| Account | Email Routing Addresses | Edit (only needed for forward rules) |

- **Zone Resources:** *Include → Specific zone* for each of your domains, or
  *All zones from an account*.
- **Account Resources:** your account.
- **Client IP filtering:** optionally your laptop's or server's IP.
- **TTL:** a short expiry, such as a day. You only need the token while you
  run the script.

The **Account ID** is on any zone's **Overview** page, in the right-hand
column under *API*.

### 8.2 Write the config

```bash
$ cp deploy/cloudflare/email-routing.conf.example deploy/cloudflare/email-routing.conf
$ $EDITOR deploy/cloudflare/email-routing.conf
```

The format is one rule per line: `<zone> <address|*> <worker|forward|drop> [target]`.

```
example.com   support@example.com   worker   singlestack-inbound-mail
example.com   reply@example.com     worker   singlestack-inbound-mail
example.com   hello@example.com     forward  you@your-mailbox.example
example.com   *                     drop
example.org   support@example.org   worker   singlestack-inbound-mail
example.org   *                     forward  you@your-mailbox.example
example.net   *                     forward  you@your-mailbox.example
```

The real file is git-ignored because it contains personal addresses.

### 8.3 Plan, apply, verify

```bash
$ export CLOUDFLARE_API_TOKEN=…          # from §8.1; don't put it in .env
$ export CLOUDFLARE_ACCOUNT_ID=…
$ make email-routing-plan                 # read-only: prints  + create  ~ update  = ok  ? unmanaged  ! warning  ✗ problem
$ make email-routing-apply                # performs the plan
$ make email-routing-plan                 # should now say: no changes
$ make email-routing-status               # settings, SPF, rules and expected DNS per zone
$ unset CLOUDFLARE_API_TOKEN
```

Example plan output:

```
==> zone example.com
  = Email Routing enabled (status: ready)
  ! SPF lacks Cloudflare. Edit it to: v=spf1 include:_spf.mx.cloudflare.net include:spf.brevo.com ~all
  ~ set subaddressing on
  + reply@example.com -> worker singlestack-inbound-mail
  ~ catch-all -> drop (was: disabled)
  ? unmanaged: legacy@example.com -> forward you@your-mailbox.example (enabled=true) — left as is
==> zone example.net
  ✗ example.net has non-Cloudflare MX records; Email Routing would replace that mail service:
        MX 1 aspmx.l.google.com
```

| Variable | Default | Meaning |
|---|---|---|
| `SUBADDRESSING` | `on` | set `off` to disable plus-address matching on every listed zone |
| `CF_API` | `https://api.cloudflare.com/client/v4` | override for testing (`tests/cf-email-routing/` uses a local mock) |

Exit code `0` means everything converged. `1` means at least one ✗ problem
needs attention. The other zones were still processed.

### 8.4 API reference (what the script calls)

| Purpose | Request |
|---|---|
| find zone | `GET /zones?name=<zone>` |
| read settings | `GET /zones/{zone}/email/routing` |
| enable (adds + locks DNS) | `POST /zones/{zone}/email/routing/dns` `{"name":"<zone>"}` |
| subaddressing | `PATCH /zones/{zone}/email/routing` `{"support_subaddress":true}` |
| expected DNS records | `GET /zones/{zone}/email/routing/dns` |
| list / create / update rules | `GET`, `POST /zones/{zone}/email/routing/rules`; `PUT …/rules/{id}` |
| catch-all | `GET`, `PUT /zones/{zone}/email/routing/rules/catch_all` |
| destination addresses | `GET`, `POST /accounts/{account}/email/routing/addresses` |
| MX / SPF inspection | `GET /zones/{zone}/dns_records?type=MX|TXT&name=<zone>` |

Rule body:

```json
{
  "name": "support@example.com (managed by singlestack)",
  "enabled": true,
  "matchers": [{ "type": "literal", "field": "to", "value": "support@example.com" }],
  "actions":  [{ "type": "worker", "value": ["singlestack-inbound-mail"] }]
}
```

---

## 9. Verify end to end

Run these per domain, *(laptop)*:

```bash
dig +short MX example.com                               # three routeN.mx.cloudflare.net
dig +short TXT example.com | grep spf                   # one record incl. _spf.mx.cloudflare.net
dig +short TXT cf2024-1._domainkey.example.com          # v=DKIM1; …
```

Then send real mail **from an outside account** such as Gmail. Mail sent from
the same domain sometimes takes shortcuts and proves nothing.

| Send to | Expect |
|---|---|
| `hello@example.com` | arrives in `you@your-mailbox.example` within seconds |
| `nobody-here@example.com` | follows your catch-all choice: dropped, forwarded, or a bounce if disabled |
| `support@example.com` | `wrangler tail` shows `"event":"relayed"` and a Chatwoot conversation appears (after chapters 5–8) |
| reply to Chatwoot's answer | lands in the **same** conversation (§6.1) |

**Email Routing → (domain) → Overview / Activity log** shows each message's
outcome (*Forwarded*, *Dropped*, *Rejected*, *Delivery failed*) and the reason.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Onboarding error **2008** "Non-Cloudflare MX records exist" | Another provider's MX is present | §4.3: choose option A, B or C |
| Status *Misconfigured* | A locked record was edited, deleted, or never added | **Settings → DNS records** shows which one; re-add it, or disable and re-enable Email Routing |
| Forward rule shows inactive | Destination not verified | §5: resend the verification and click the link |
| Sender gets "Address does not exist" | No rule for that address and no catch-all | add a rule, or enable the catch-all |
| Replies to Chatwoot open new conversations or bounce | Subaddressing off, or no `reply@` rule | §6.1 and §6.2; check the Activity log for `reply+…` |
| Activity log: *Worker error / exception* | Worker misconfigured or Chatwoot down without a fallback | chapter 5, §5.6; `npx wrangler tail` |
| Forwarded mail lands in the destination's spam | Original sender has weak SPF/DMARC; forwarding breaks SPF | normal for some senders. Mark it as not spam. DKIM-signed mail is unaffected. |
| Two SPF records | Cloudflare's and an existing one | merge into one record (§4.4) |
| `dig` still shows old MX | Resolver cache | wait for the old TTL; compare with `dig @1.1.1.1` |
| Messages > 25 MiB rejected | Platform limit | Ask senders to use a file link instead. Nothing can be configured. |

## 11. Disabling Email Routing

**Email Routing → Settings → Disable Email Routing** removes the MX, SPF and
DKIM records it added. Mail stops being accepted as soon as resolvers notice.
Moving to another provider? Unlock the records first (§4.2), add the new
provider's MX alongside them, verify, then disable. An unlocked record that
you edited is **still** deleted on disable.

Next: [4. Brevo](04-brevo.md)
