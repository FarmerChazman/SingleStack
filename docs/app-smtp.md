# Sending from your own apps (TruckTrips, Farm Analyser, Combine Analyser, …)

Apps send through Brevo directly. This stack isn't in that path, so it can be
down without breaking password resets or other transactional mail.

## Per app

1. In **Brevo → SMTP & API → SMTP → Generate a new SMTP key**, name the key
   after the app, e.g. `trucktrips-prod`.
2. Make sure the app's From domain is authenticated in Brevo
   ([email-and-dns.md §1](email-and-dns.md#1-brevo-sending)).
3. Give the app these settings (the variable names vary by framework):

```dotenv
SMTP_HOST=smtp-relay.brevo.com
SMTP_PORT=587               # STARTTLS. Use 465 for implicit TLS if the library prefers it.
SMTP_USER=<your Brevo SMTP login, e.g. 1a2b3c@smtp-brevo.com>
SMTP_PASSWORD=<the app's own key>
SMTP_FROM="TruckTrips <no-reply@trucktrips.example>"
```

- **Django:** `EMAIL_HOST`, `EMAIL_PORT=587`, `EMAIL_USE_TLS=True`,
  `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`.
- **FastAPI / Celery** (fastapi-mail or `smtplib`): `MAIL_SERVER`,
  `MAIL_PORT=587`, `MAIL_STARTTLS=True`, `MAIL_SSL_TLS=False`.
- **Node** (nodemailer): `{ host, port: 587, secure: false, auth: { user, pass } }`.

## Rules of thumb

- **One key per app and environment.** If a key leaks, revoke only that key.
- **Transactional only.** Bulk or marketing mail goes through Listmonk, so
  unsubscribe handling and rate limits stay in one place.
- **Replies.** Set `Reply-To: support@yourdomain.com` on user-facing mail, so
  replies become Chatwoot conversations instead of disappearing into
  `no-reply@`.
- **Plan limits.** Brevo's daily cap is shared across all keys on the account.
  Watch Brevo → Statistics if campaigns and app mail grow together.
