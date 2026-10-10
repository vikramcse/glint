// License keys and activation tokens, byte-compatible with Sources/GlintLicensing
// (LicensePayload + LicenseTokenCodec): `GLINT1-` + base64url(payload JSON) + "." +
// base64url(Ed25519 signature over the payload bytes). Payload JSON has sorted keys and
// whole-second integer dates; `installID` is omitted for license keys.

export const TOKEN_PREFIX = "GLINT1-";
export const PRODUCT = "glint-pro";
export const MAJOR_VERSION = 1;
export const DEFAULT_SEATS = 2;

export type TokenKind = "license" | "activation";

export interface LicensePayload {
  licenseID: string;
  product: string;
  majorVersion: number;
  seats: number;
  /** Seconds since 1970. */
  issuedAt: number;
  emailHash: string;
  installID?: string;
  kind: TokenKind;
}

export type TokenFailure = "malformed" | "tampered" | "wrongProduct" | "wrongVersion" | "wrongKind" | "wrongDevice";

export class TokenError extends Error {
  readonly reason: TokenFailure;

  constructor(reason: TokenFailure) {
    super(reason);
    this.reason = reason;
  }
}

// MARK: Encoding

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64urlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function base64urlDecode(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  const base64 = text.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  try {
    return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
  } catch {
    return null;
  }
}

export function base64Decode(text: string): Uint8Array {
  return Uint8Array.from(atob(text.trim()), (char) => char.charCodeAt(0));
}

export function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Canonical payload bytes: sorted keys, integer seconds, no optional nulls. */
export function encodePayload(payload: LicensePayload): Uint8Array {
  const fields: Record<string, unknown> = {
    emailHash: payload.emailHash,
    issuedAt: Math.floor(payload.issuedAt),
    kind: payload.kind,
    licenseID: payload.licenseID,
    majorVersion: payload.majorVersion,
    product: payload.product,
    seats: payload.seats,
  };
  if (payload.installID !== undefined) fields.installID = payload.installID;
  const sorted: Record<string, unknown> = {};
  for (const key of Object.keys(fields).sort()) sorted[key] = fields[key];
  return encoder.encode(JSON.stringify(sorted));
}

function decodePayload(bytes: Uint8Array): LicensePayload | null {
  try {
    const value = JSON.parse(decoder.decode(bytes)) as Partial<LicensePayload>;
    if (
      typeof value.licenseID !== "string" ||
      typeof value.product !== "string" ||
      typeof value.majorVersion !== "number" ||
      typeof value.seats !== "number" ||
      typeof value.issuedAt !== "number" ||
      typeof value.emailHash !== "string" ||
      (value.kind !== "license" && value.kind !== "activation")
    ) {
      return null;
    }
    return value as LicensePayload;
  } catch {
    return null;
  }
}

// MARK: Keys

/** PKCS#8 prefix for a raw 32-byte Ed25519 seed (RFC 8410). */
const PKCS8_PREFIX = Uint8Array.from([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
]);

export interface SigningKeys {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
  /** Raw 32-byte public key, base64 — the value compiled into the app (LicensePublicKey.swift). */
  publicKeyBase64: string;
}

/**
 * Imports the base64 raw private key used by Swift's `Curve25519.Signing.PrivateKey`
 * (`rawRepresentation`), as written by `glint-license keygen`.
 */
export async function importSigningKeys(privateKeyBase64: string): Promise<SigningKeys> {
  const seed = base64Decode(privateKeyBase64);
  if (seed.length !== 32) throw new Error("LICENSE_PRIVATE_KEY must be a base64 raw 32-byte Ed25519 key");
  const pkcs8 = new Uint8Array(PKCS8_PREFIX.length + seed.length);
  pkcs8.set(PKCS8_PREFIX);
  pkcs8.set(seed, PKCS8_PREFIX.length);
  const privateKey = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, true, ["sign"]);
  const jwk = (await crypto.subtle.exportKey("jwk", privateKey)) as JsonWebKey;
  if (!jwk.x) throw new Error("Could not derive the public key");
  const publicRaw = base64urlDecode(jwk.x);
  if (!publicRaw) throw new Error("Could not derive the public key");
  const publicKey = await crypto.subtle.importKey("raw", publicRaw, { name: "Ed25519" }, true, ["verify"]);
  return { privateKey, publicKey, publicKeyBase64: base64Encode(publicRaw) };
}

// MARK: Sign and verify

export async function signToken(payload: LicensePayload, keys: SigningKeys): Promise<string> {
  const bytes = encodePayload(payload);
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, keys.privateKey, bytes));
  return `${TOKEN_PREFIX}${base64urlEncode(bytes)}.${base64urlEncode(signature)}`;
}

/** Mirrors `LicenseVerifier.verify` in the app. */
export async function verifyToken(
  token: string,
  keys: Pick<SigningKeys, "publicKey">,
  options: { kind?: TokenKind; installID?: string } = {},
): Promise<LicensePayload> {
  const cleaned = token.replace(/\s+/g, "");
  if (!cleaned.startsWith(TOKEN_PREFIX)) throw new TokenError("malformed");
  const parts = cleaned.slice(TOKEN_PREFIX.length).split(".");
  if (parts.length !== 2) throw new TokenError("malformed");
  const payloadBytes = base64urlDecode(parts[0]!);
  const signature = base64urlDecode(parts[1]!);
  if (!payloadBytes || !signature) throw new TokenError("malformed");
  const valid = await crypto.subtle.verify({ name: "Ed25519" }, keys.publicKey, signature, payloadBytes);
  if (!valid) throw new TokenError("tampered");
  const payload = decodePayload(payloadBytes);
  if (!payload) throw new TokenError("malformed");
  if (payload.product !== PRODUCT) throw new TokenError("wrongProduct");
  if (payload.majorVersion !== MAJOR_VERSION) throw new TokenError("wrongVersion");
  if (options.kind && payload.kind !== options.kind) throw new TokenError("wrongKind");
  if (payload.kind === "activation") {
    if (!payload.installID) throw new TokenError("malformed");
    if (options.installID && payload.installID !== options.installID) throw new TokenError("wrongDevice");
  }
  return payload;
}

/** SHA-256 of the trimmed, lowercased email, hex — matches `LicensePayload.hashEmail`. */
export async function hashEmail(email: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(email.trim().toLowerCase()));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
