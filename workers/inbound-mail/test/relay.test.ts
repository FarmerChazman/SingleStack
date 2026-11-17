import { test } from "node:test";
import assert from "node:assert/strict";
import { buildRelayBody, headerSafe, relayToChatwoot, type FetchLike } from "../src/relay.ts";

const dec = new TextDecoder();
const raw = new TextEncoder().encode("To: support@example.com\r\nSubject: hi\r\n\r\nbody");
const noSleep = async () => {};

test("prepends X-Original-To and keeps the message intact", () => {
  const out = dec.decode(buildRelayBody("support@example.com", raw));
  assert.equal(out, "X-Original-To: support@example.com\r\nTo: support@example.com\r\nSubject: hi\r\n\r\nbody");
});

test("envelope address cannot inject headers", () => {
  assert.equal(headerSafe("a@b.c\r\nBcc: evil@x.y"), "a@b.c Bcc: evil@x.y");
});

test("sends rfc822 with basic auth for actionmailbox", async () => {
  let seen: RequestInit | undefined;
  const fetchFn: FetchLike = async (_url, init) => ((seen = init), new Response(null, { status: 204 }));
  const r = await relayToChatwoot(raw, { url: "https://x/ingress", password: "pw", fetchFn });
  assert.deepEqual(r, { ok: true, status: 204, attempts: 1 });
  const h = seen!.headers as Record<string, string>;
  assert.equal(h["Content-Type"], "message/rfc822");
  assert.equal(h.Authorization, "Basic " + btoa("actionmailbox:pw"));
});

test("retries 5xx and network errors, then succeeds", async () => {
  const replies = [() => Promise.reject(new TypeError("boom")), async () => new Response(null, { status: 502 }), async () => new Response(null, { status: 204 })];
  let i = 0;
  const r = await relayToChatwoot(raw, { url: "u", password: "p", fetchFn: () => replies[i++]!(), sleep: noSleep });
  assert.deepEqual(r, { ok: true, status: 204, attempts: 3 });
});

test("does not retry 4xx (config error)", async () => {
  let calls = 0;
  const fetchFn: FetchLike = async () => (calls++, new Response(null, { status: 401 }));
  const r = await relayToChatwoot(raw, { url: "u", password: "bad", fetchFn, sleep: noSleep });
  assert.equal(calls, 1);
  assert.deepEqual(r, { ok: false, reason: "HTTP 401", attempts: 1 });
});

test("gives up after the configured attempts", async () => {
  const fetchFn: FetchLike = async () => new Response(null, { status: 503 });
  const r = await relayToChatwoot(raw, { url: "u", password: "p", attempts: 2, fetchFn, sleep: noSleep });
  assert.deepEqual(r, { ok: false, reason: "HTTP 503", attempts: 2 });
});
