# 10. Sending from your own applications

Your other applications (SaaS products, internal tools, scripts) should send
their transactional mail (sign-up confirmations, password resets, receipts,
alerts) **directly through Brevo**, not through Chatwoot or Listmonk. That
way, a problem with this stack never blocks a password reset.

```
your-app ──SMTP 587──► Brevo ──► recipient
                         ▲
Chatwoot ────────────────┤   (separate keys, same authenticated domains)
Listmonk ────────────────┘
```

## 10.1 Per application

1. **Authenticate the app's From domain** in Brevo (ch. 4, §4.2) and
   register the sender (§4.3), e.g. `Example App <no-reply@example.com>`.
2. **Create a dedicated SMTP key** named `app-<name>-<env>`, e.g.
   `app-billing-prod` (ch. 4, §4.4). Use separate keys for staging and
   production.
3. **Configure the app.**

Generic settings:

```dotenv
SMTP_HOST=smtp-relay.brevo.com
SMTP_PORT=587
SMTP_SECURE=false            # STARTTLS upgrade on 587; use 465 + implicit TLS only if required
SMTP_USER=<Login from Brevo → SMTP & API>
SMTP_PASSWORD=<this app's SMTP key>
MAIL_FROM="Example App <no-reply@example.com>"
MAIL_REPLY_TO=support@example.com
```

Framework equivalents:

**Django**

```python
EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
EMAIL_HOST = "smtp-relay.brevo.com"
EMAIL_PORT = 587
EMAIL_USE_TLS = True          # STARTTLS
EMAIL_USE_SSL = False
EMAIL_HOST_USER = env("SMTP_USER")
EMAIL_HOST_PASSWORD = env("SMTP_PASSWORD")
DEFAULT_FROM_EMAIL = "Example App <no-reply@example.com>"
EMAIL_TIMEOUT = 15
```

**FastAPI** (`fastapi-mail`)

```python
ConnectionConfig(
    MAIL_SERVER="smtp-relay.brevo.com", MAIL_PORT=587,
    MAIL_STARTTLS=True, MAIL_SSL_TLS=False,
    MAIL_USERNAME=settings.smtp_user, MAIL_PASSWORD=settings.smtp_password,
    MAIL_FROM="no-reply@example.com", MAIL_FROM_NAME="Example App",
    USE_CREDENTIALS=True, VALIDATE_CERTS=True, TIMEOUT=15,
)
```

**Python standard library**

```python
import smtplib, ssl
from email.message import EmailMessage

msg = EmailMessage()
msg["From"], msg["To"], msg["Subject"] = "Example App <no-reply@example.com>", "user@example.net", "Hello"
msg["Reply-To"] = "support@example.com"
msg.set_content("Plain-text body")

with smtplib.SMTP("smtp-relay.brevo.com", 587, timeout=15) as s:
    s.starttls(context=ssl.create_default_context())
    s.login(SMTP_USER, SMTP_PASSWORD)
    s.send_message(msg)
```

**Node.js** (nodemailer)

```js
const transporter = nodemailer.createTransport({
  host: "smtp-relay.brevo.com",
  port: 587,
  secure: false,             // STARTTLS
  requireTLS: true,
  auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASSWORD },
});
```

**Laravel**

```dotenv
MAIL_MAILER=smtp
MAIL_HOST=smtp-relay.brevo.com
MAIL_PORT=587
MAIL_ENCRYPTION=tls
MAIL_USERNAME=...
MAIL_PASSWORD=...
MAIL_FROM_ADDRESS=no-reply@example.com
```

## 10.2 Good practice

- **Set `Reply-To: support@example.com`** on user-facing mail. Users who hit
  *Reply* on a `no-reply@` message then reach Chatwoot instead of nowhere.
- **Send from a worker or queue, not inside the web request.** SMTP can take
  seconds, and a queue with retries survives brief relay hiccups.
- **Make sends idempotent** where possible, e.g. by storing a sent flag per
  receipt, so retries don't duplicate mail.
- **Keep marketing out of app SMTP.** Bulk or marketing mail belongs in
  Listmonk, so unsubscribes, consent and rate limits are handled in one place.
- **Watch the shared daily cap.** All keys on a Brevo account share one quota.
  If campaigns and app mail together approach it, upgrade the plan, or lower
  Listmonk's sliding window (ch. 8 §8.2.4) so password resets always get
  through.
- **Use test mode in development.** Point non-production environments at a
  local catcher such as Mailpit, or a separate Brevo key, so test mail never
  reaches real users.

## 10.3 Verify

Send one message from the app to an outside mailbox, then check **Show
original** for DKIM `pass` with `d=example.com` and DMARC `pass`, and find it
in **Brevo → Transactional → Logs** under the app's key.
