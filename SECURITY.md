# Security policy

Glint indexes private files and can expose search to local agents, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Report privately through [GitHub's private vulnerability reporting](https://github.com/vikramcse/glint/security/advisories/new) and include:

- what an attacker can do, and from where (another local user, a web page, a process on the same Mac, a malicious file or bucket)
- steps to reproduce, and the Glint and macOS versions
- any proof of concept

You'll get an acknowledgement within 72 hours. Fixes are released as soon as they're ready, and reporters are credited in the release notes unless they'd rather not be.

## Supported versions

Only the latest release gets security fixes.

## What's in scope

- **The local API and `glint-mcp`:** auth bypass, token leaks, reachability from outside loopback, browser or DNS-rebinding access. The design is in [docs/local-api.md](docs/local-api.md).
- **Remote sources:** leaks of S3 credentials from the Keychain, or requests going anywhere other than the configured endpoint. See [docs/remote-sources.md](docs/remote-sources.md).
- **Parsing untrusted files:** crashes, hangs or memory blowups from crafted PDFs, images, audio, video or archives.
- **Model download:** any way to get unverified weights loaded.
- **Updates:** anything that weakens Sparkle's signature checks.
- **Privacy:** any network traffic beyond the model download, update checks and sources you added.
