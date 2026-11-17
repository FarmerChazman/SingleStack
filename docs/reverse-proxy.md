# Publishing Chatwoot and Listmonk

The stack publishes nothing on public interfaces. Chatwoot listens on
`127.0.0.1:3001` and Listmonk on `127.0.0.1:3002` (`CHATWOOT_BIND` /
`LISTMONK_BIND` in `.env`).

## Recommended: Cloudflare Tunnel routes (how the farm-analyser host works)

The host runs a dashboard-managed tunnel, **`vmwebt1650`**. Its cloudflared
reaches services on the host's `localhost`; for example, `portal.` goes to
`http://localhost:80` and `combine.` goes to `http://localhost:8088`. So
neither nginx nor any Docker network change is needed.

In **Zero Trust → Networks → Tunnels → vmwebt1650 → Routes → Add route →
Published application**, add:

| Hostname | Service |
|---|---|
| `support.farmanalyser.com` | `http://localhost:3001` |
| `lists.farmanalyser.com` | `http://localhost:3002` |

Cloudflare creates the proxied `Tunnel` DNS records itself. TLS is handled at
Cloudflare, as it is for the existing hostnames. Websockets (Chatwoot's
`/cable`) work through tunnels with no extra settings.

Check from your laptop:

```bash
curl -sI https://support.farmanalyser.com/health   # 200
curl -sI https://lists.farmanalyser.com/health     # 200
```

## Alternative: through an nginx container

Use this only if you want nginx in the path, for example to share config with
`farmanalyser-nginx`. Inside a container, `127.0.0.1` is the container itself,
so nginx reaches the stack over the Docker network `edge` by container name
(`ss-chatwoot:3000`, `ss-listmonk:9000`).

1. Attach nginx to `edge` persistently. In its compose file:

   ```yaml
   services:
     nginx:
       networks: [default, edge]     # keep its existing networks
   networks:
     edge:
       external: true
   ```

2. Copy `deploy/nginx/singlestack.conf` into its `conf.d`. Replace
   `example.com`, then run `nginx -t && nginx -s reload`.
3. Point the tunnel routes at nginx (`http://localhost:80`) instead of at
   ports 3001/3002.

If cloudflared ever runs as a container instead of on the host, attach it to
`edge` and use `deploy/cloudflared/config.example.yml`.

## Cloudflare Access for Listmonk admin (recommended)

Go to **Zero Trust → Access → Applications → Self-hosted** and create:

| Application | Path | Policy |
|---|---|---|
| Listmonk admin | `lists.farmanalyser.com/admin` | Allow: your email(s) |
| Listmonk API | `lists.farmanalyser.com/api` | Allow: your email(s) |
| Listmonk public API | `lists.farmanalyser.com/api/public` | **Bypass**: everyone |

The bypass is needed because subscription forms post to `/api/public/…`. Leave
`support.` without Access: the chat widget and the inbound-mail worker must
reach it, and Chatwoot has its own login and 2FA.
