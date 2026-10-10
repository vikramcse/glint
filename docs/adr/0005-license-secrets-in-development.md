# ADR 0005: Keychain for signed builds, a private file for ad hoc builds

**Status:** Accepted · 2026-10-10

## Context

License tokens, the trial clock and the install id live in the Keychain. Ad hoc signatures change on every build, so the login keychain asks the user to approve each new development build, and `LicenseManager` reads the store during launch: the first development launch blocked on a Keychain prompt.

## Decision

`SecureStoreFactory.make` returns `KeychainStore` when the running code has a team identity (Developer ID builds) and a `FileSecureStore` (`license-dev.json`, mode 0600, next to the index) otherwise.

## Consequences

- Development builds never block on Keychain prompts; release builds keep secrets in the Keychain.
- The trial in a development build resets when that file is deleted, which is acceptable ("light anti-tamper only").
- Until the M3 license server exists, a validly signed key activates offline (`activationService: nil`), so seat limits are not enforced yet. `AppLinks.licenseServer` turns enforcement on.
