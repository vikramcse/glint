# ADR 0010: S3 buckets as remote sources, downloaded to index, never mounted

**Status:** Accepted · 2026-10-16

## Context

Network shares are covered by ADR 0009 because macOS mounts them. Object storage is not a file system: files have to be listed and fetched over the S3 API. Glint's promise is that indexing and search happen on the Mac, so the design must not send content anywhere, and must survive the service being slow, offline or rejecting the key.

## Decision

- **Same shape as the Photos library.** A remote source is a row in `sources` whose path is a URL, `s3://<endpoint host>/<bucket>/<prefix>`. Each file is `<root>/<key>`. Search, the vector index and thumbnails don't change: everything derived is local, so results appear and render while the bucket is unreachable.
- **`RemoteStorage` in GlintCore** (`connect`, `list`, `download`), with `RemoteService` naming the kind of service (only `s3` today). The implementation lives in a new module, **`GlintRemote`**, that depends only on GlintCore and Apple frameworks: SigV4 is written on CryptoKit and checked against AWS's published examples, listing uses ListObjectsV2 and downloads GetObject. Any S3-compatible service works (AWS, Cloudflare R2, Backblaze B2, MinIO); path-style addressing is an option.
- **Stream, don't keep.** Files are downloaded to a temporary folder, hashed and extracted, then deleted (as Photos exports are). Opening, previewing or copying a result downloads it to `Caches/Glint/RemoteDownloads`, which is cleared at launch. Files over `maxRemoteFileSize` (4 GB) are not downloaded.
- **Change detection from listings.** Every 15 minutes (`networkRescanInterval`), and on wake, each bucket is listed in full and reconciled by size and modification date. Only new or changed objects are downloaded.
- **Offline is not deleted.** A listing that fails, and a download that fails with `RemoteStorageError.unreachable` or `.unauthorized`, take the source offline (ADR 0009): its files are kept and released back to the queue. Throttling and server errors are retried with backoff first. Only a `404` for a single object removes that file.
- **Secrets in the Keychain only.** `remote_sources` (schema v3) holds the JSON `RemoteSourceConfig`: endpoint, region, bucket, prefix, access key id and a `credentialID`. The secret access key is a generic password under that id in the login Keychain, deleted with the source.
- **Schema repairs run after every migration**, not only on an up-to-date database: a drifted v2 (see `Schema.repairFaces`) that upgrades to v3 would otherwise never get its faces tables.

## Consequences

- Network traffic now includes the buckets the user adds, but only reads: listings and downloads with the user's own key. Nothing is uploaded.
- A full listing per poll is fine for tens of thousands of objects; a bucket with millions should be added by prefix.
- Videos are downloaded whole to be indexed, which can be slow on a slow link; the queue still indexes documents and images first.
- Other services (cloud drives) would be another `RemoteService` case and `RemoteStorage` conformance; they need OAuth, which was built and then removed as out of scope for now.
