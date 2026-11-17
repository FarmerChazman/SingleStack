// Pure relay logic, kept free of Workers globals so it can be unit-tested in Node.

export type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

export interface RelayOptions {
  url: string;
  password: string;
  attempts?: number;
  timeoutMs?: number;
  backoffMs?: number;
  fetchFn?: FetchLike;
  sleep?: (ms: number) => Promise<void>;
}

export type RelayResult =
  | { ok: true; status: number; attempts: number }
  | { ok: false; reason: string; attempts: number };

const encoder = new TextEncoder();

/** Strip CR/LF so an envelope address can never inject extra headers. */
export function headerSafe(value: string): string {
  return value.replace(/[\r\n]+/g, " ").trim();
}

/**
 * Prepend X-Original-To with the envelope recipient. Chatwoot's
 * EmailChannelFinder reads it, so BCC'd or aliased mail still lands in the
 * right inbox when the To: header doesn't name the support address.
 */
export function buildRelayBody(envelopeTo: string, raw: Uint8Array): Uint8Array {
  const prefix = encoder.encode(`X-Original-To: ${headerSafe(envelopeTo)}\r\n`);
  const out = new Uint8Array(prefix.length + raw.length);
  out.set(prefix, 0);
  out.set(raw, prefix.length);
  return out;
}

export function basicAuth(user: string, password: string): string {
  return "Basic " + btoa(`${user}:${password}`);
}

/**
 * POST a raw RFC 822 message to Rails' Action Mailbox relay ingress.
 * Retries network errors and 5xx; 4xx (bad password, wrong content type) are
 * configuration errors and fail immediately.
 */
export async function relayToChatwoot(body: Uint8Array, opts: RelayOptions): Promise<RelayResult> {
  const attempts = opts.attempts ?? 3;
  const timeoutMs = opts.timeoutMs ?? 15_000;
  const backoffMs = opts.backoffMs ?? 750;
  const fetchFn = opts.fetchFn ?? ((i, init) => fetch(i, init));
  const sleep = opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));

  let reason = "not attempted";
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const res = await fetchFn(opts.url, {
        method: "POST",
        headers: {
          "Content-Type": "message/rfc822",
          Authorization: basicAuth("actionmailbox", opts.password),
          "User-Agent": "singlestack-inbound-mail",
        },
        body,
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (res.ok) return { ok: true, status: res.status, attempts: attempt };
      reason = `HTTP ${res.status}`;
      if (res.status < 500) return { ok: false, reason, attempts: attempt };
    } catch (err) {
      reason = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    }
    if (attempt < attempts) await sleep(backoffMs * attempt);
  }
  return { ok: false, reason, attempts };
}
