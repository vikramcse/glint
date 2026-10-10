import Foundation

/// The Ed25519 public key that verifies Glint license keys and activation tokens.
///
/// The matching private key never ships in the app. This is the **development** key; its
/// private half lives in `secrets/license-dev-private.key` (gitignored). Rotate to the
/// production key held only by the license server before the public beta.
public enum LicensePublicKey {
    public static let base64 = "HHH9k+KIKBqAEWqZUd4yWyMYDwntbvgk5r9oVdTrnwY="
}
