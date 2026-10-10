-- Licenses issued by the store (or imported the first time a signed key is activated).
CREATE TABLE licenses (
    id TEXT PRIMARY KEY,              -- LicensePayload.licenseID
    email_hash TEXT NOT NULL,         -- SHA-256 of the lowercased email; never the email itself
    seats INTEGER NOT NULL DEFAULT 2,
    provider TEXT,                    -- 'lemonsqueezy', 'paddle', 'manual', 'imported'
    order_id TEXT UNIQUE,             -- merchant order id, for refunds and idempotent webhooks
    created_at INTEGER NOT NULL
);

-- One row per Mac holding a seat.
CREATE TABLE activations (
    license_id TEXT NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
    install_id TEXT NOT NULL,         -- random per-install UUID from the app's Keychain
    activated_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    PRIMARY KEY (license_id, install_id)
);

-- Refunded or charged-back licenses. The app fetches this at most weekly.
CREATE TABLE revocations (
    license_id TEXT PRIMARY KEY,
    reason TEXT NOT NULL,             -- 'refund', 'chargeback', 'manual'
    revoked_at INTEGER NOT NULL
);

-- Webhook deliveries already processed (merchants retry).
CREATE TABLE webhook_events (
    id TEXT PRIMARY KEY,
    received_at INTEGER NOT NULL
);
