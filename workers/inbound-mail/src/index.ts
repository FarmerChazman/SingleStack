// Cloudflare Email Worker: Email Routing -> Chatwoot (Action Mailbox relay ingress).
//
// Route in Cloudflare Email Routing:
//   support@<domain>          -> this worker   (one rule per support address / brand)
//   *@<CHATWOOT_INBOUND_DOMAIN> -> this worker (catch-all; reply+<uuid>@ continuity)
//
// If Chatwoot can't be reached, the message is forwarded to FALLBACK_FORWARD
// (a verified destination) so nothing is lost. Without a fallback the handler
// throws and Cloudflare reports the failure to the sending server.

import { buildRelayBody, relayToChatwoot } from "./relay";

export interface Env {
  CHATWOOT_INBOUND_URL: string;
  CHATWOOT_INBOUND_PASSWORD: string; // wrangler secret put CHATWOOT_INBOUND_PASSWORD
  FALLBACK_FORWARD?: string;
}

const MAX_BYTES = 25 * 1024 * 1024; // Cloudflare's inbound limit

export default {
  async email(message: ForwardableEmailMessage, env: Env): Promise<void> {
    const meta = { from: message.from, to: message.to, size: message.rawSize };

    if (!env.CHATWOOT_INBOUND_URL || !env.CHATWOOT_INBOUND_PASSWORD) {
      console.error(JSON.stringify({ event: "misconfigured", ...meta }));
      return fallbackOrThrow(message, env, "worker misconfigured");
    }
    if (message.rawSize > MAX_BYTES) {
      message.setReject("Message too large");
      return;
    }

    const raw = new Uint8Array(await new Response(message.raw).arrayBuffer());
    const result = await relayToChatwoot(buildRelayBody(message.to, raw), {
      url: env.CHATWOOT_INBOUND_URL,
      password: env.CHATWOOT_INBOUND_PASSWORD,
    });

    if (result.ok) {
      console.log(JSON.stringify({ event: "relayed", status: result.status, attempts: result.attempts, ...meta }));
      return;
    }
    console.error(JSON.stringify({ event: "relay_failed", reason: result.reason, attempts: result.attempts, ...meta }));
    return fallbackOrThrow(message, env, result.reason);
  },
} satisfies ExportedHandler<Env>;

async function fallbackOrThrow(message: ForwardableEmailMessage, env: Env, reason: string): Promise<void> {
  if (env.FALLBACK_FORWARD) {
    const headers = new Headers({ "X-Singlestack-Relay": `failed; ${reason}`.slice(0, 200) });
    await message.forward(env.FALLBACK_FORWARD, headers);
    console.warn(JSON.stringify({ event: "forwarded_fallback", to: env.FALLBACK_FORWARD }));
    return;
  }
  throw new Error(`chatwoot relay failed: ${reason}`);
}
