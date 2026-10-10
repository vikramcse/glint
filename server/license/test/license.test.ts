import { env, SELF } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { LicenseStore } from "../src/db.ts";
import { defaultDependencies, type Dependencies, handle } from "../src/index.ts";
import { ConsoleMailer } from "../src/mailer.ts";
import { LemonSqueezyAdapter } from "../src/merchant.ts";
import {
  encodePayload,
  hashEmail,
  importSigningKeys,
  type LicensePayload,
  type SigningKeys,
  signToken,
  TokenError,
  verifyToken,
} from "../src/tokens.ts";

const fixture = JSON.parse(env.TOKEN_FIXTURE) as {
  publicKeyBase64: string;
  installID: string;
  workerLicenseKey: string;
  workerActivationToken: string;
  swiftLicenseKey: string;
};

let keys: SigningKeys;
let counter = 0;

beforeAll(async () => {
  keys = await importSigningKeys(env.LICENSE_PRIVATE_KEY);
});

function installID(): string {
  counter += 1;
  return `6F1C2B3A-4D5E-4F60-8172-${counter.toString(16).padStart(12, "0").toUpperCase()}`;
}

async function issueKey(overrides: Partial<LicensePayload> = {}): Promise<string> {
  return signToken(
    {
      licenseID: crypto.randomUUID(),
      product: "glint-pro",
      majorVersion: 1,
      seats: 2,
      issuedAt: 1_791_600_000,
      emailHash: await hashEmail("buyer@example.com"),
      kind: "license",
      ...overrides,
    },
    keys,
  );
}

function post(path: string, body: unknown): Promise<Response> {
  return SELF.fetch(`https://license.test${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function activate(key: string, install: string): Promise<Response> {
  return post("/v1/activate", { key, install_id: install });
}

describe("token format shared with the Swift app", () => {
  it("derives the same public key the Swift tool printed", () => {
    expect(fixture.publicKeyBase64).toBe("krQJkYQsawnbXfbutA9TAZZIoiXub5KXz0RrPVUGB1g=");
    expect(keys.publicKeyBase64).toBe(fixture.publicKeyBase64);
  });

  it("accepts a key signed by the Swift glint-license tool and re-encodes it byte for byte", async () => {
    const payload = await verifyToken(fixture.swiftLicenseKey, keys, { kind: "license" });
    expect(payload.emailHash).toBe(await hashEmail("Buyer@Example.com"));
    const swiftPayloadBytes = fixture.swiftLicenseKey.slice("GLINT1-".length).split(".")[0];
    const reencoded = btoa(String.fromCharCode(...encodePayload(payload)))
      .replaceAll("+", "-")
      .replaceAll("/", "_")
      .replaceAll("=", "");
    expect(reencoded).toBe(swiftPayloadBytes);
  });

  it("reproduces the committed fixture tokens exactly (Ed25519 is deterministic)", async () => {
    const license = await verifyToken(fixture.workerLicenseKey, keys, { kind: "license" });
    expect(await signToken(license, keys)).toBe(fixture.workerLicenseKey);
    const activation = await verifyToken(fixture.workerActivationToken, keys, {
      kind: "activation",
      installID: fixture.installID,
    });
    expect(await signToken(activation, keys)).toBe(fixture.workerActivationToken);
  });

  it("rejects tampered, wrong-product and wrong-device tokens", async () => {
    const [body, signature] = fixture.workerLicenseKey.slice(7).split(".");
    const flipped = `GLINT1-${body!.slice(0, -2)}${body!.endsWith("A") ? "B" : "A"}${body!.slice(-1)}.${signature}`;
    await expect(verifyToken(flipped, keys)).rejects.toBeInstanceOf(TokenError);
    await expect(verifyToken(await issueKey({ product: "other" }), keys)).rejects.toMatchObject({ reason: "wrongProduct" });
    await expect(verifyToken(await issueKey({ majorVersion: 2 }), keys)).rejects.toMatchObject({ reason: "wrongVersion" });
    await expect(
      verifyToken(fixture.workerActivationToken, keys, { kind: "activation", installID: "OTHER-INSTALL" }),
    ).rejects.toMatchObject({ reason: "wrongDevice" });
  });
});

describe("activation API", () => {
  it("activates, enforces two seats, and re-activates the same Mac idempotently", async () => {
    const key = await issueKey();
    const [first, second, third] = [installID(), installID(), installID()];

    const response = await activate(key, first);
    expect(response.status).toBe(200);
    const { activation } = (await response.json()) as { activation: string };
    const payload = await verifyToken(activation, keys, { kind: "activation", installID: first });
    expect(payload.seats).toBe(2);

    expect((await activate(key, second)).status).toBe(200);
    expect((await activate(key, first)).status).toBe(200);
    const blocked = await activate(key, third);
    expect(blocked.status).toBe(409);
  });

  it("frees a seat on deactivate", async () => {
    const key = await issueKey();
    const [first, second, third] = [installID(), installID(), installID()];
    const { activation } = (await (await activate(key, first)).json()) as { activation: string };
    await activate(key, second);
    expect((await activate(key, third)).status).toBe(409);

    const freed = await post("/v1/deactivate", { activation, install_id: first });
    expect(freed.status).toBe(204);
    expect((await activate(key, third)).status).toBe(200);
  });

  it("refuses to deactivate with another Mac's install id", async () => {
    const key = await issueKey();
    const first = installID();
    const { activation } = (await (await activate(key, first)).json()) as { activation: string };
    expect((await post("/v1/deactivate", { activation, install_id: installID() })).status).toBe(422);
  });

  it("maps bad input to statuses the app understands", async () => {
    expect((await activate("not a key", installID())).status).toBe(422);
    expect((await activate(await issueKey({ product: "other" }), installID())).status).toBe(422);
    expect((await post("/v1/activate", { key: await issueKey() })).status).toBe(422);
    const malformed = await SELF.fetch("https://license.test/v1/activate", { method: "POST", body: "{" });
    expect(malformed.status).toBe(400);
    expect((await SELF.fetch("https://license.test/nope")).status).toBe(404);
  });

  it("reports revocation through validate and blocks new activations", async () => {
    const key = await issueKey();
    const install = installID();
    const { activation } = (await (await activate(key, install)).json()) as { activation: string };
    const before = await SELF.fetch(`https://license.test/v1/validate?activation=${encodeURIComponent(activation)}`);
    expect(await before.json()).toEqual({ revoked: false });

    const payload = await verifyToken(key, keys);
    await new LicenseStore(env.DB).revoke(payload.licenseID, "manual", 1);
    const after = await SELF.fetch(`https://license.test/v1/validate?activation=${encodeURIComponent(activation)}`);
    expect(await after.json()).toEqual({ revoked: true });
    expect((await activate(key, installID())).status).toBe(410);
  });

  it("rejects unknown keys in strict mode", async () => {
    const deps = await defaultDependencies(env);
    const request = new Request("https://license.test/v1/activate", {
      method: "POST",
      body: JSON.stringify({ key: await issueKey(), install_id: installID() }),
    });
    const response = await handle(request, { ...env, STRICT_KEYS: "true" }, deps);
    expect(response.status).toBe(404);
  });
});

describe("Lemon Squeezy webhooks", () => {
  async function signed(body: string, secret = "test-webhook-secret"): Promise<Request> {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
      "sign",
    ]);
    const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(body)));
    const signature = [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    return new Request("https://license.test/webhooks/lemonsqueezy", {
      method: "POST",
      headers: { "X-Signature": signature, "Content-Type": "application/json" },
      body,
    });
  }

  function order(event: string, orderID: string, extra: Record<string, unknown> = {}): string {
    return JSON.stringify({
      meta: { event_name: event },
      data: {
        id: orderID,
        attributes: { status: "paid", user_email: "Buyer@Example.com", first_order_item: { quantity: 1 }, ...extra },
      },
    });
  }

  async function dependencies(): Promise<Dependencies & { mailer: ConsoleMailer }> {
    const deps = await defaultDependencies(env);
    return { ...deps, mailer: new ConsoleMailer() };
  }

  it("issues and emails a working key for a paid order, once", async () => {
    const deps = await dependencies();
    const body = order("order_created", "1001");
    expect((await handle(await signed(body), env, deps)).status).toBe(200);
    expect((await handle(await signed(body), env, deps)).status).toBe(200);
    expect(deps.mailer.sent).toHaveLength(1);

    const email = deps.mailer.sent[0]!;
    expect(email.to).toBe("Buyer@Example.com");
    const payload = await verifyToken(email.licenseKey, keys, { kind: "license" });
    expect(payload.emailHash).toBe(await hashEmail("buyer@example.com"));
    expect((await activate(email.licenseKey, installID())).status).toBe(200);
  });

  it("gives two seats per unit purchased", async () => {
    const deps = await dependencies();
    await handle(await signed(order("order_created", "1002", { first_order_item: { quantity: 3 } })), env, deps);
    const payload = await verifyToken(deps.mailer.sent[0]!.licenseKey, keys);
    expect(payload.seats).toBe(6);
  });

  it("revokes on refund", async () => {
    const deps = await dependencies();
    await handle(await signed(order("order_created", "1003")), env, deps);
    const key = deps.mailer.sent[0]!.licenseKey;
    const { activation } = (await (await activate(key, installID())).json()) as { activation: string };

    expect((await handle(await signed(order("order_refunded", "1003")), env, deps)).status).toBe(200);
    const validate = await SELF.fetch(`https://license.test/v1/validate?activation=${encodeURIComponent(activation)}`);
    expect(await validate.json()).toEqual({ revoked: true });
  });

  it("rejects bad signatures and ignores unpaid or unrelated events", async () => {
    const deps = await dependencies();
    expect((await handle(await signed(order("order_created", "1004"), "wrong-secret"), env, deps)).status).toBe(401);
    await handle(await signed(order("order_created", "1005", { status: "pending" })), env, deps);
    await handle(await signed(order("subscription_created", "1006")), env, deps);
    expect(deps.mailer.sent).toHaveLength(0);
  });

  it("parses the provider payload into a neutral event", () => {
    const adapter = new LemonSqueezyAdapter("x");
    expect(adapter.parse(order("order_created", "77"))).toEqual({
      type: "orderPaid",
      eventID: "lemonsqueezy:order_created:77",
      orderID: "77",
      email: "Buyer@Example.com",
      quantity: 1,
    });
    expect(adapter.parse("{")).toBeNull();
  });
});

describe("self-service seats page", () => {
  function form(fields: Record<string, string>): Promise<Response> {
    return SELF.fetch("https://license.test/seats", { method: "POST", body: new URLSearchParams(fields) });
  }

  it("lists and frees seats only for the matching email", async () => {
    const key = await issueKey();
    const install = installID();
    await activate(key, install);

    const wrong = await form({ key, email: "someone@else.com" });
    expect(wrong.status).toBe(403);

    const listing = await (await form({ key, email: "Buyer@example.com " })).text();
    expect(listing).toContain("1 of 2 seats in use");
    expect(listing).toContain(install.slice(-6));

    const freed = await (await form({ key, email: "buyer@example.com", free: install })).text();
    expect(freed).toContain("Seat freed");
    expect(freed).toContain("0 of 2 seats in use");
  });

  it("serves the form and escapes input", async () => {
    expect((await SELF.fetch("https://license.test/seats")).status).toBe(200);
    const response = await form({ key: "<script>", email: "a@b.c" });
    expect(response.status).toBe(422);
    expect(await response.text()).not.toContain("<script>");
  });
});
