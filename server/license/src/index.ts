// Glint license server: activation, deactivation and revocation for Glint Pro, plus the
// merchant webhook that issues and revokes licenses. It stores license ids, email hashes
// and random install ids; never file data, emails at rest, or hardware identifiers.
//
// API (must match Sources/GlintLicensing/ActivationService.swift):
//   POST /v1/activate   {"key", "install_id"}        → 200 {"activation"} | 409 seats | 410 revoked | 422 invalid
//   POST /v1/deactivate {"activation", "install_id"} → 204 | 422 invalid
//   GET  /v1/validate?activation=…                   → 200 {"revoked": bool} | 422 invalid
//   POST /webhooks/lemonsqueezy                      → 200 (signature-verified)
//   GET|POST /seats                                  → self-service page to free seats

import { LicenseStore } from "./db.ts";
import { ConsoleMailer, type Mailer, ResendMailer } from "./mailer.ts";
import { LemonSqueezyAdapter, type MerchantAdapter } from "./merchant.ts";
import { seatsPage } from "./seats.ts";
import {
  DEFAULT_SEATS,
  hashEmail,
  importSigningKeys,
  MAJOR_VERSION,
  PRODUCT,
  type SigningKeys,
  signToken,
  TokenError,
  verifyToken,
} from "./tokens.ts";

export interface Env {
  DB: D1Database;
  /** Base64 raw Ed25519 private key (`glint-license keygen`). Set with `wrangler secret put`. */
  LICENSE_PRIVATE_KEY: string;
  LEMONSQUEEZY_WEBHOOK_SECRET?: string;
  RESEND_API_KEY?: string;
  MAIL_FROM?: string;
  /** "true" rejects signed keys that the store never issued (default: accept and import them). */
  STRICT_KEYS?: string;
}

export interface Dependencies {
  keys: SigningKeys;
  store: LicenseStore;
  mailer: Mailer;
  merchants: Record<string, MerchantAdapter>;
  now: () => number;
}

/** Imported once per isolate; re-imported only if the secret changes. */
let cachedKeys: { source: string; keys: Promise<SigningKeys> } | undefined;

export async function defaultDependencies(env: Env): Promise<Dependencies> {
  if (cachedKeys?.source !== env.LICENSE_PRIVATE_KEY) {
    cachedKeys = { source: env.LICENSE_PRIVATE_KEY, keys: importSigningKeys(env.LICENSE_PRIVATE_KEY) };
  }
  return {
    keys: await cachedKeys.keys,
    store: new LicenseStore(env.DB),
    mailer: env.RESEND_API_KEY
      ? new ResendMailer(env.RESEND_API_KEY, env.MAIL_FROM ?? "Glint <licenses@glint.app>")
      : new ConsoleMailer(),
    merchants: { lemonsqueezy: new LemonSqueezyAdapter(env.LEMONSQUEEZY_WEBHOOK_SECRET ?? "") },
    now: () => Math.floor(Date.now() / 1000),
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, await defaultDependencies(env));
  },
} satisfies ExportedHandler<Env>;

export async function handle(request: Request, env: Env, deps: Dependencies): Promise<Response> {
  const url = new URL(request.url);
  try {
    switch (`${request.method} ${url.pathname}`) {
      case "POST /v1/activate":
        return await activate(request, env, deps);
      case "POST /v1/deactivate":
        return await deactivate(request, deps);
      case "GET /v1/validate":
        return await validate(url, deps);
      case "GET /seats":
      case "POST /seats":
        return await seatsPage(request, deps);
      case "GET /health":
        return json({ ok: true });
      default: {
        const webhook = url.pathname.match(/^\/webhooks\/([a-z]+)$/);
        if (request.method === "POST" && webhook?.[1] && deps.merchants[webhook[1]]) {
          return await handleWebhook(request, deps.merchants[webhook[1]]!, deps);
        }
        return json({ error: "not_found" }, 404);
      }
    }
  } catch (error) {
    if (error instanceof BadRequest) return json({ error: error.message }, 400);
    console.error("Unhandled error", error instanceof Error ? error.message : "unknown");
    return json({ error: "server_error" }, 500);
  }
}

// MARK: Activation API

async function activate(request: Request, env: Env, deps: Dependencies): Promise<Response> {
  const body = await readJSON<{ key?: string; install_id?: string }>(request);
  if (!body.key || !isInstallID(body.install_id)) return json({ error: "invalid_request" }, 422);
  const key = await verifyOr422(body.key, deps, { kind: "license" });
  if (key instanceof Response) return key;

  if (await deps.store.isRevoked(key.licenseID)) return json({ error: "revoked" }, 410);
  let license = await deps.store.license(key.licenseID);
  if (!license) {
    // The signature is the authority: keys made with `glint-license issue` are imported the
    // first time they are activated, unless the server only accepts keys the store issued.
    if (env.STRICT_KEYS === "true") return json({ error: "unknown_license" }, 404);
    license = {
      id: key.licenseID,
      email_hash: key.emailHash,
      seats: key.seats,
      provider: "imported",
      order_id: null,
      created_at: deps.now(),
    };
    await deps.store.insertLicense(license);
  }

  const installID = body.install_id;
  if (!(await deps.store.claimSeat(license.id, installID, license.seats, deps.now()))) {
    return json({ error: "seat_limit_reached", seats: license.seats }, 409);
  }
  const activation = await signToken(
    { ...key, seats: license.seats, installID, kind: "activation", issuedAt: deps.now() },
    deps.keys,
  );
  return json({ activation });
}

async function deactivate(request: Request, deps: Dependencies): Promise<Response> {
  const body = await readJSON<{ activation?: string; install_id?: string }>(request);
  if (!body.activation || !isInstallID(body.install_id)) return json({ error: "invalid_request" }, 422);
  const token = await verifyOr422(body.activation, deps, { kind: "activation", installID: body.install_id });
  if (token instanceof Response) return token;
  await deps.store.releaseSeat(token.licenseID, body.install_id);
  return new Response(null, { status: 204 });
}

async function validate(url: URL, deps: Dependencies): Promise<Response> {
  const activation = url.searchParams.get("activation");
  if (!activation) return json({ error: "invalid_request" }, 422);
  const token = await verifyOr422(activation, deps, {});
  if (token instanceof Response) return token;
  if (token.installID) await deps.store.touch(token.licenseID, token.installID, deps.now());
  return json({ revoked: await deps.store.isRevoked(token.licenseID) });
}

async function verifyOr422(token: string, deps: Dependencies, options: Parameters<typeof verifyToken>[2]) {
  try {
    return await verifyToken(token, deps.keys, options);
  } catch (error) {
    if (error instanceof TokenError) return json({ error: error.reason }, 422);
    throw error;
  }
}

// MARK: Webhooks

async function handleWebhook(request: Request, merchant: MerchantAdapter, deps: Dependencies): Promise<Response> {
  const body = await request.text();
  if (!(await merchant.verify(request, body))) return json({ error: "bad_signature" }, 401);
  const event = merchant.parse(body);
  if (!event) return json({ error: "malformed" }, 400);
  if (event.type === "ignored") return json({ ok: true, ignored: true });
  if (!(await deps.store.markEventProcessed(event.eventID, deps.now()))) return json({ ok: true, duplicate: true });

  switch (event.type) {
    case "orderPaid": {
      if (await deps.store.licenseForOrder(event.orderID)) return json({ ok: true });
      const seats = DEFAULT_SEATS * event.quantity;
      const payload = {
        licenseID: crypto.randomUUID(),
        product: PRODUCT,
        majorVersion: MAJOR_VERSION,
        seats,
        issuedAt: deps.now(),
        emailHash: await hashEmail(event.email),
        kind: "license" as const,
      };
      await deps.store.insertLicense({
        id: payload.licenseID,
        email_hash: payload.emailHash,
        seats,
        provider: merchant.name,
        order_id: event.orderID,
        created_at: payload.issuedAt,
      });
      const licenseKey = await signToken(payload, deps.keys);
      await deps.mailer.sendLicense({ to: event.email, licenseKey, seats });
      return json({ ok: true });
    }
    case "refund":
    case "chargeback": {
      const license = await deps.store.licenseForOrder(event.orderID);
      if (license) await deps.store.revoke(license.id, event.type, deps.now());
      return json({ ok: true });
    }
  }
}

// MARK: Helpers

class BadRequest extends Error {}

async function readJSON<T>(request: Request): Promise<T> {
  try {
    return (await request.json()) as T;
  } catch {
    throw new BadRequest("invalid_json");
  }
}

function isInstallID(value: unknown): value is string {
  return typeof value === "string" && /^[0-9A-Fa-f-]{8,64}$/.test(value);
}

export function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
