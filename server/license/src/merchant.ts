// Merchant-of-record webhooks behind one interface, so Paddle can be added beside Lemon Squeezy.

/** What the license server needs to know from a store event. */
export type MerchantEvent =
  | { type: "orderPaid"; eventID: string; orderID: string; email: string; quantity: number }
  | { type: "refund"; eventID: string; orderID: string }
  | { type: "chargeback"; eventID: string; orderID: string }
  | { type: "ignored"; eventID: string };

export interface MerchantAdapter {
  /** Short name stored with each license ("lemonsqueezy"). */
  readonly name: string;
  /** Verifies the delivery came from the merchant. `body` is the raw request body. */
  verify(request: Request, body: string): Promise<boolean>;
  /** Maps the payload to a merchant-neutral event, or null when it is malformed. */
  parse(body: string): MerchantEvent | null;
}

async function hmacSHA256Hex(secret: string, body: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(body));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Constant-time comparison of two hex strings. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  return difference === 0;
}

/**
 * Lemon Squeezy: `X-Signature` is the hex HMAC-SHA256 of the raw body with the webhook's
 * signing secret. Subscribe the webhook to `order_created` and `order_refunded`.
 */
export class LemonSqueezyAdapter implements MerchantAdapter {
  readonly name = "lemonsqueezy";
  private readonly signingSecret: string;

  constructor(signingSecret: string) {
    this.signingSecret = signingSecret;
  }

  async verify(request: Request, body: string): Promise<boolean> {
    const signature = request.headers.get("X-Signature");
    if (!signature || !this.signingSecret) return false;
    return timingSafeEqual(signature.toLowerCase(), await hmacSHA256Hex(this.signingSecret, body));
  }

  parse(body: string): MerchantEvent | null {
    let json: {
      meta?: { event_name?: string; webhook_id?: string };
      data?: {
        id?: string | number;
        attributes?: {
          user_email?: string;
          status?: string;
          refunded?: boolean;
          first_order_item?: { quantity?: number };
        };
      };
    };
    try {
      json = JSON.parse(body);
    } catch {
      return null;
    }
    const event = json.meta?.event_name;
    const orderID = json.data?.id === undefined ? undefined : String(json.data.id);
    if (!event || !orderID) return null;
    const eventID = `${this.name}:${event}:${orderID}`;
    const attributes = json.data?.attributes ?? {};
    switch (event) {
      case "order_created": {
        if (attributes.status !== "paid" || !attributes.user_email) return { type: "ignored", eventID };
        const quantity = Math.max(1, Math.floor(attributes.first_order_item?.quantity ?? 1));
        return { type: "orderPaid", eventID, orderID, email: attributes.user_email, quantity };
      }
      case "order_refunded":
        return { type: "refund", eventID, orderID };
      default:
        return { type: "ignored", eventID };
    }
  }
}
