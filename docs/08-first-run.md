# 8. First run: Chatwoot and Listmonk

By now: Email Routing is enabled (ch. 3), Brevo is authenticated (ch. 4), the
Worker is deployed (ch. 5), the stack is running (ch. 6), and both hostnames
answer (ch. 7).

## 8.1 Chatwoot

### 8.1.1 Create the super-admin

1. Open `https://support.example.com`. A fresh installation shows the
   **onboarding** screen.
2. Enter your name, company, email and a strong password. This user becomes
   the installation's **super admin** and the administrator of the first
   **account** (Chatwoot's word for a workspace).
3. Log in, then **Profile settings → Security**: enable **two-factor
   authentication**.

Sign-ups are disabled (`CHATWOOT_ENABLE_SIGNUP=false`), so nobody else can
create accounts. Invite people under **Settings → Agents → Add agent**. The
invitation is sent through Brevo, which also tests outbound mail.

**Super Admin console:** `https://support.example.com/super_admin` handles
installation-wide settings, accounts and users. You're unlikely to need it
for this setup.

### 8.1.2 Create the Email inbox (one per support address)

1. **Settings → Inboxes → Add Inbox → Email.**
2. Choose **Other Providers** (sometimes labelled *Forwarding*). Don't choose
   Gmail or Microsoft: those connect a mailbox over OAuth and IMAP, which
   this stack doesn't use.
3. **Channel name:** e.g. `Support — Example`. **Email:**
   `support@example.com`.
4. Add the agents who should see these conversations, then **Finish**.
5. Chatwoot displays a *forwarding address* (`…@<CHATWOOT_INBOUND_DOMAIN>`).
   **You don't need it**: the Worker delivers mail for `support@example.com`
   directly, and Chatwoot matches the inbox by its email address.
6. Open the inbox → **Settings**:
   - **Configuration → Outgoing email:** leave SMTP/IMAP **disabled**. The
     inbox then sends through the installation's SMTP (Brevo, from `.env`).
     The From address is the inbox's address, so that domain must be
     authenticated in Brevo (ch. 4, §4.2).
   - **Settings → Email signature:** optional.

Repeat for every brand's support address (`support@example.org`, …).

### 8.1.3 Account-level settings

**Settings → Account settings:**

- **Account name, language, auto-resolve:** as you prefer.
- **Domain** (shown when inbound email is enabled): leave it empty to use
  `CHATWOOT_INBOUND_DOMAIN`, or set a brand domain for this account. If you
  set one, that domain needs its own `reply@` rule and subaddressing (ch. 3,
  §6.3).
- **Support email:** the default sender for this account's system mail.

### 8.1.4 Optional: website live chat

**Settings → Inboxes → Add Inbox → Website**, enter your site's URL, then
paste the generated `<script>` snippet before `</body>` on your site. The
widget connects to `support.example.com`. For conversations started in the
widget, Chatwoot emails transcripts and replies to visitors who left an email
address, and their replies come back through the same `reply+<uuid>@` path.

### 8.1.5 ✓ Checkpoint: the full support round trip

1. From an outside mailbox (e.g. Gmail), send *"test 1"* to
   `support@example.com`.
2. Within about 10 seconds, a conversation appears in the inbox.
   *Not there?* See ch. 5, §5.6 (`wrangler tail`).
3. Reply from Chatwoot. The reply arrives in Gmail from
   `support@example.com`. **Show original** should show DKIM and DMARC pass.
   Hovering *Reply* shows `reply+<uuid>@example.com`.
4. Reply from Gmail with *"test 2"*. It lands in the **same** conversation.
   *A new conversation, or a bounce?* See ch. 3, §6.1 (subaddressing).

## 8.2 Listmonk

### 8.2.1 Log in

Open `https://lists.example.com/admin`, which Cloudflare Access may guard
(ch. 7, §7.5). Log in with `LISTMONK_ADMIN_USER` and
`LISTMONK_ADMIN_PASSWORD` from `.env`. **Immediately** go to **Users** →
your user → set a new password, and enable 2FA if your version offers it.

### 8.2.2 General settings

**Settings → General:**

| Field | Value | Why |
|---|---|---|
| Root URL | `https://lists.example.com` | builds every unsubscribe, tracking and archive link. If it's wrong, every link in every campaign is broken. |
| Default 'from' email | `Example News <news@example.com>` | domain authenticated in Brevo; registered as a sender |
| Admin notification e-mails | your address | import and campaign status |
| Send opt-in confirmation | on | double opt-in for public subscriptions |

Save. Listmonk restarts its internal workers.

### 8.2.3 SMTP

**Settings → SMTP**. Edit the default server, or delete it and add one:

| Field | Value |
|---|---|
| Enabled | ✓ |
| Host | `smtp-relay.brevo.com` |
| Port | `587` |
| Auth protocol | `LOGIN` |
| Username | the Login from Brevo → SMTP & API |
| Password | the **`singlestack-listmonk`** SMTP key (not Chatwoot's) |
| TLS | `STARTTLS` |
| Skip TLS verify | off |
| Max. connections | `5` |
| Retries | `2` |
| Idle timeout / Wait timeout | `15s` / `5s` |

Save, then click **Test connection** / **Send test e-mail** and check that it
arrives.

### 8.2.4 Respect Brevo's daily limit

**Settings → Performance:**

| Field | Value | Meaning |
|---|---|---|
| Concurrency | `5` | parallel send workers |
| Message rate | `5` per second | stays well under relay rate limits |
| Batch size | `1000` | subscribers fetched per DB query |
| Enable sliding window | ✓ | caps the total sent in a time window |
| Window duration | `24h` | |
| Window rate | your Brevo daily cap minus app traffic, e.g. `250` on the free plan | Listmonk **pauses** the campaign when the limit is reached and resumes in the next window |

With 300 mails a day on Brevo's free plan, a 2,000-subscriber campaign takes
about eight days. Either accept that, or upgrade Brevo and raise the window
rate.

### 8.2.5 Media, privacy, bounces

- **Settings → Media:** provider **filesystem**, upload path
  `/listmonk/uploads`. This is the `listmonk_uploads` volume, which is backed
  up. URI: `/uploads`.
- **Settings → Privacy:**
  - **Individual subscriber tracking:** off, unless you need per-person opens.
    Aggregate stats still work, and this is friendlier under GDPR.
  - **Allow un-subscription / Allow preferences / Allow export / Allow
    wipe:** on.
- **Bounces:** Brevo suppresses hard bounces and complaints on its own side,
  so repeated sends to dead addresses are blocked there. Feeding Brevo
  webhooks into Listmonk's bounce API is a possible extension, not configured
  here.

### 8.2.6 Lists, templates and a first campaign

1. **Lists → New:** e.g. `Newsletter`, type **Public**, opt-in **Double**.
2. **Campaigns → Templates:** start from the default and add your logo and
   address. Keep `{{ UnsubscribeURL }}`: it's legally required in most
   jurisdictions, and Gmail and Yahoo require one-click unsubscribe for bulk
   senders. Listmonk adds the `List-Unsubscribe` headers.
3. **Lists → Forms:** generate the subscription form HTML for your website,
   or use the hosted page at `https://lists.example.com/subscription/form`.
4. **Campaigns → New:** choose the list, send a **test** to yourself, check
   links and **Show original** (DKIM/DMARC pass, `List-Unsubscribe` present),
   then **Start**.

✓ **Checkpoint:** subscribe through the public form with an outside address,
confirm the opt-in email, receive the test campaign, and use the unsubscribe
link. The subscriber then shows as *unsubscribed* in Listmonk.

Next: [9. Operations](09-operations.md)
