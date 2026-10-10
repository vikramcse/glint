# Glint license server

This is a Cloudflare Worker with a D1 database. It handles three things for Glint Pro:

- Activates, deactivates and checks revocation for licenses.
- Receives the store's webhook, which issues license keys and revokes refunded ones.
- Serves a small self-service page at `/seats` where buyers can free a seat.

Search never depends on this server. The app verifies tokens offline and only contacts the server to activate, deactivate, and check for revocation (at most weekly). Network failures are ignored.

**What it stores:**
- License ids.
- SHA-256 hashes of buyer emails.
- Random per-install UUIDs.

**What it never stores:** email addresses, file data, or hardware identifiers.

## API

These endpoints are what `HTTPActivationService` in `Sources/GlintLicensing/ActivationService.swift` calls.

| Request | Response |
| --- | --- |
| `POST /v1/activate` `{"key", "install_id"}` | `200 {"activation"}`. `409` if every seat is taken, `410` if revoked, `422` if the key is invalid. |
| `POST /v1/deactivate` `{"activation", "install_id"}` | `204`. `422` if the token is invalid or belongs to another Mac. |
| `GET /v1/validate?activation=…` | `200 {"revoked": bool}`. `422` if the token is invalid. |
| `POST /webhooks/lemonsqueezy` | `200`. `401` if the signature is bad. |
| `GET` or `POST /seats` | Self-service page: enter key and purchase email, then free a seat. |

**Tokens** use the app's format: `GLINT1-` + base64url(payload JSON with sorted keys and integer seconds) + `.` + base64url(Ed25519 signature).

- **Activation tokens** are the buyer's key payload with `kind: "activation"` and `installID` added, so a token can't be copied to another Mac.
- **Seat limit** is the license's `seats` value: 2 per unit purchased.
- **Keys the store didn't issue** (for example, made with `glint-license issue`) are accepted and imported the first time they're activated, because the signature is the authority. To accept only keys the store issued, set `STRICT_KEYS=true`.

## Deploy

1. **Create a signing keypair** and keep the private half only in Cloudflare:

   ```sh
   swift run glint-license keygen        # prints private and public keys (base64)
   ```

   Put the **public** key in `Sources/GlintLicensing/LicensePublicKey.swift`. That replaces the development key, and app builds must ship with it.

2. **Create the database and apply the schema:**

   ```sh
   cd server/license
   npm install
   npx wrangler login
   npx wrangler d1 create glint-licenses         # copy database_id into wrangler.jsonc
   npm run db:migrate
   ```

3. **Set the secrets:**

   ```sh
   npx wrangler secret put LICENSE_PRIVATE_KEY            # base64 private key from step 1
   npx wrangler secret put LEMONSQUEEZY_WEBHOOK_SECRET    # from the Lemon Squeezy webhook
   npx wrangler secret put RESEND_API_KEY                 # optional; without it, emails are only logged
   ```

4. **Deploy:** run `npm run deploy`. Add a custom domain (for example `licenses.glint.app`) in the Cloudflare dashboard.

5. **Point the app at it:** set `GlintLicenseServerURL` in `App/Info.plist` to the deployed URL. Leave it empty to keep offline activation, where any validly signed key works with no seat limit.

6. **Set up Lemon Squeezy:**
   - Create the product (one-time, $49).
   - Add a webhook to `https://<your-domain>/webhooks/lemonsqueezy` for `order_created` and `order_refunded`, using the same signing secret as step 3.
   - Set `GlintPurchaseURL` in `App/Info.plist` to the checkout link.

### Email

When `RESEND_API_KEY` is set, keys are sent through Resend from `MAIL_FROM` (set in `wrangler.jsonc`). To use another provider, implement the `Mailer` interface in `src/mailer.ts`.

### Adding Paddle

Implement `MerchantAdapter` in `src/merchant.ts`:

- **Signature check:** `Paddle-Signature` is an HMAC over `ts:body`.
- **Event mapping:** map `transaction.completed` to `orderPaid`, `adjustment.created` with action `refund` to `refund`, and with action `chargeback` to `chargeback`.

Then register it in `defaultDependencies` under `paddle`. It becomes available at `/webhooks/paddle`.

## Development

```sh
npm test            # vitest inside the Workers runtime (Miniflare + D1)
npm run typecheck
npm run dev         # local server; run npm run db:migrate:local first
npm run fixture     # regenerate the cross-language token fixture
```

**The cross-language fixture:**
- `test/fixtures/tokens.json` holds tokens signed by this Worker and a key signed by the Swift `glint-license` tool.
- The same file is copied to `Tests/GlintLicensingTests/Fixtures/worker-tokens.json`.
- The app's tests verify the Worker's tokens, and these tests verify the Swift key and check that both sides produce identical payload bytes.

**The test key:** `test/fixtures/test-private.key` is a published **test** key. Never use it as `LICENSE_PRIVATE_KEY`.
