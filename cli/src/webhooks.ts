import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Signed webhooks. Endpoints are operator-configured only (never taken from
 * requests), so a caller cannot point this at internal services.
 *
 * Each delivery is a POST with a JSON body:
 *   { type: "<event>", idempotencyKey, createdAt, data: <payload> }
 * and headers
 *   tpm-webhook-id: <idempotencyKey>
 *   tpm-signature:  t=<unix seconds>,v1=<hex HMAC-SHA256(secret, `${t}.${body}`)>
 * Receivers verify the signature, reject stale timestamps, and dedupe on
 * idempotencyKey (a delivery can be retried after a timeout).
 */
export interface WebhookEndpoint {
  url: string;
  /** HMAC secret, >= 32 chars. */
  secret: string;
}

export interface WebhookEvent<T = unknown> {
  type: "transaction.status" | "governance.alert" | "energy.alert";
  idempotencyKey: string;
  createdAt: number;
  data: T;
}

export function signWebhook(secret: string, body: string, t = Math.floor(Date.now() / 1000)): string {
  const mac = createHmac("sha256", secret).update(`${t}.${body}`).digest("hex");
  return `t=${t},v1=${mac}`;
}

/** Verifies a `tpm-signature` header. For receivers; `toleranceSeconds` bounds replay. */
export function verifyWebhook(secret: string, body: string, header: string, toleranceSeconds = 300, now = Math.floor(Date.now() / 1000)): boolean {
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=", 2) as [string, string]));
  const t = Number(parts.t);
  if (!Number.isInteger(t) || !parts.v1 || Math.abs(now - t) > toleranceSeconds) return false;
  const want = Buffer.from(createHmac("sha256", secret).update(`${t}.${body}`).digest("hex"));
  const got = Buffer.from(parts.v1);
  return want.length === got.length && timingSafeEqual(want, got);
}

export interface WebhookDispatcher {
  /** Queues an arbitrary event; `idempotencyKey` must be stable for the same fact. */
  send(event: WebhookEvent<unknown>): void;
  /** Resolves when queued deliveries have finished (for shutdown and tests). */
  drain(): Promise<void>;
}

export function createWebhookDispatcher(opts: {
  endpoints: WebhookEndpoint[];
  fetch?: typeof fetch;
  /** Delivery attempts per endpoint (default 6: ~0s, 1s, 4s, 16s, 64s, 256s). */
  attempts?: number;
  baseDelayMs?: number;
  timeoutMs?: number;
  log?: (msg: string, extra?: Record<string, unknown>) => void;
}): WebhookDispatcher {
  for (const e of opts.endpoints) {
    const u = new URL(e.url);
    if (u.protocol !== "https:" && !(u.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(u.hostname))) {
      throw new Error(`webhook ${e.url}: https required (http only for localhost)`);
    }
    if (e.secret.length < 32) throw new Error(`webhook ${e.url}: secret must be >= 32 chars`);
  }
  const fetchFn = opts.fetch ?? globalThis.fetch.bind(globalThis);
  const attempts = opts.attempts ?? 6;
  const base = opts.baseDelayMs ?? 1000;
  const log = opts.log ?? (() => {});
  const inflight = new Set<Promise<void>>();

  async function deliver(e: WebhookEndpoint, body: string, id: string) {
    for (let i = 0; i < attempts; i++) {
      if (i > 0) await new Promise((r) => setTimeout(r, base * 4 ** (i - 1)));
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs ?? 10_000);
      try {
        const res = await fetchFn(e.url, {
          method: "POST",
          headers: { "content-type": "application/json", "tpm-webhook-id": id, "tpm-signature": signWebhook(e.secret, body) },
          body,
          signal: ctrl.signal,
          redirect: "error",
        });
        if (res.ok) return;
        // 4xx other than 408/429 means the receiver rejected it; don't hammer.
        if (res.status < 500 && res.status !== 408 && res.status !== 429) {
          log("webhook rejected", { url: e.url, status: res.status, id });
          return;
        }
      } catch {
        // network error or timeout: retry
      } finally {
        clearTimeout(timer);
      }
    }
    log("webhook delivery failed", { url: e.url, id });
  }

  const dispatcher: WebhookDispatcher = {
    send(event) {
      if (!opts.endpoints.length) return;
      const body = JSON.stringify(event, (_k, v) => (typeof v === "bigint" ? v.toString() : v));
      for (const e of opts.endpoints) {
        const p = deliver(e, body, event.idempotencyKey).finally(() => inflight.delete(p));
        inflight.add(p);
      }
    },
    async drain() {
      while (inflight.size) await Promise.allSettled([...inflight]);
    },
  };
  return dispatcher;
}
