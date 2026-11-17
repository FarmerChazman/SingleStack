# 7. Publishing the web UIs

Chatwoot (`127.0.0.1:3001`) and Listmonk (`127.0.0.1:3002`) need public
HTTPS hostnames. Chatwoot needs one for agents, the chat widget and the
inbound-mail Worker. Listmonk needs one for subscribe and unsubscribe pages,
tracking links and its admin UI. The recommended way is **Cloudflare
Tunnel**: no open ports, TLS handled by Cloudflare, and DNS created for you.

| Situation | Section |
|---|---|
| You already run a tunnel whose `cloudflared` is on this host | §7.1 |
| No tunnel yet | §7.2 |
| You want an nginx (or other proxy) container in front | §7.3 |

## 7.1 Add routes to an existing tunnel

A *remotely managed* tunnel is configured in the dashboard. You can tell by
its routes, which look like `http://localhost:<port>`.

1. **Zero Trust → Networks → Tunnels →** *your tunnel* **→ Routes → Add route
   → Published application.** (Older dashboards: *Configure → Public
   Hostname → Add a public hostname*.)
2. Add:

   | Subdomain | Domain | Path | Service type | URL |
   |---|---|---|---|---|
   | `support` | `example.com` | (empty) | HTTP | `localhost:3001` |
   | `lists` | `example.com` | (empty) | HTTP | `localhost:3002` |

3. Save. Cloudflare creates proxied DNS records of type **Tunnel** for both
   hostnames. Don't create them by hand.

Routes are matched top to bottom. A wildcard route (`*.example.com`) placed
above these would catch them first, so drag the new routes above any
wildcards.

**Why `localhost` works:** `cloudflared` runs on the host (as a systemd
service or with `network_mode: host`), so `localhost` is the host itself,
where the stack's ports are bound. If your `cloudflared` runs in an ordinary
Docker container instead, `localhost` is that container. In that case, use
§7.3's network approach with the URLs `http://ss-chatwoot:3000` and
`http://ss-listmonk:9000`.

## 7.2 Create a tunnel

1. **Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared.** Name
   it after the server.
2. Choose the server's OS. Cloudflare shows an install command containing a
   token, typically:

   ```bash
   sudo cloudflared service install <TOKEN>
   ```

   This installs `cloudflared` as a systemd service with the token embedded.
3. The connector shows **Healthy** in the dashboard within a minute.
4. Add the two routes as in §7.1.

The tunnel only makes outbound connections (to Cloudflare on 443 or 7844), so
no firewall changes are needed.

## 7.3 Alternative: through a proxy container (nginx)

Use this if an nginx container already fronts your other sites and you want
a single point for headers, logging or rate limits. Inside a container,
`127.0.0.1` is the container itself, not the host, so the proxy reaches the
stack over the shared Docker network `edge` (created by `make up`), using
container names.

1. **Attach the proxy to `edge`, persistently.** In the proxy's own compose
   file:

   ```yaml
   services:
     nginx:
       networks: [default, edge]        # keep the networks it already has
   networks:
     edge:
       external: true
   ```

   Then `docker compose up -d nginx` in that project.
   (`docker network connect edge <container>` also works, but it's lost the
   next time the container is recreated.)

2. **Install the vhosts.** Copy `deploy/nginx/singlestack.conf` into the
   proxy's `conf.d`, replace `example.com`, and reload:

   ```bash
   docker exec <nginx> nginx -t && docker exec <nginx> nginx -s reload
   ```

   The file is self-contained:
   - Upstreams resolve through Docker DNS at request time (`resolver
     127.0.0.11`), so nginx still starts when the stack is down.
   - It uses a `$ss_`-prefixed websocket `map`, which can't collide with an
     existing `$connection_upgrade`.
   - `client_max_body_size 40m` on `support.` allows 25 MiB messages from
     the Worker plus attachments.
   - It sends `X-Forwarded-Proto: https`, because TLS ends at Cloudflare.

3. **Point the tunnel routes (or DNS) at the proxy** instead of ports 3001 and
   3002.

If a containerised `cloudflared` should talk to the stack directly, attach it
to `edge` and use `deploy/cloudflared/config.example.yml`.

## 7.4 Requirements the publishing layer must meet

| Requirement | Why | Tunnel | nginx |
|---|---|---|---|
| WebSockets on `/cable` | Chatwoot live updates | works by default | `Upgrade` / `Connection` headers (included) |
| Request bodies ≥ 30 MB on `support.` | 25 MiB raw emails from the Worker | no limit to configure on Cloudflare plans | `client_max_body_size` (included) |
| `X-Forwarded-Proto: https` | correct redirect and cookie URLs | set by Cloudflare | set in the vhost |
| No caching of `/api`, `/cable`, `/rails/*` | dynamic | default Cloudflare rules don't cache HTML or API | — |
| No Cloudflare Access on `support.` paths used by customers or the Worker | widget and mail must work anonymously | see §7.5 | — |

## 7.5 Protect the Listmonk admin with Cloudflare Access (recommended)

Listmonk's admin has its own login, but there's no reason to expose it to
the internet. **Zero Trust → Access → Applications → Add an application →
Self-hosted:**

| Application | Domain / path | Policy |
|---|---|---|
| Listmonk admin | `lists.example.com` / `admin` | **Allow**, Include → Emails → your addresses |
| Listmonk API | `lists.example.com` / `api` | **Allow**, same |
| Listmonk public API | `lists.example.com` / `api/public` | **Bypass**, Include → Everyone |

The bypass application is required because public subscription forms post to
`/api/public/subscription`. The more specific path wins. Public pages
(`/subscription/*`, `/link/*`, `/campaign/*`, `/archive`) stay open.

**Don't** put Access in front of `support.` as a whole. The chat widget
(`/api/v1/widget`, `/packs`, `/cable`) and the Worker
(`/rails/action_mailbox/…`) must stay reachable. Chatwoot has its own login
and 2FA. If you want Access for agents, scope it to `/app` only, and test the
widget and an inbound mail afterwards.

## 7.6 Verify

*(laptop)*

```bash
curl -s https://support.example.com/health        # {"status":"woot"}
curl -s https://lists.example.com/health           # {"data":true}
curl -sI https://support.example.com/ | head -1    # HTTP/2 200 (or 302 to the login page)
```

`make doctor` on the server should now report both public hostnames as ✓.

Next: [8. First run](08-first-run.md)
