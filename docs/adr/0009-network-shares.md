# ADR 0009: Network shares as folder sources, kept current by polling

**Status:** Accepted · 2026-10-15

## Context

Glint should search folders that live on other machines: network shares first, and later S3-compatible buckets and cloud drives. A share that macOS mounts (SMB, NFS, AFP) already looks like a folder under `/Volumes`, so it could be added as a source before this change. Two gaps made that unreliable:

- **FSEvents only reports changes made on this Mac.** A file another machine adds to the share is never seen until a full rescan, which only happened at launch or on "Re-index".
- **A disconnected share looked like deleted files.** Scans already refused to reconcile an unreadable root, but two other paths did not check. The watcher removed any changed path that no longer existed, and the pipeline deleted a pending file it could not find (`.vanished`). Dropping the share while files were queued, or receiving FSEvents for its mount point as it went away, removed index entries that were still valid. The same applied to unplugged external drives.

## Decision

- **Shares stay folder sources.** `VolumeProbing` (real: `SystemVolumeProbe`, which uses `volumeIsLocal`) tells the indexer whether a source is on a network volume and whether it is reachable now. It is injected, so tests simulate a share disconnecting.
- **Offline sources.** The indexer keeps `offlineSources`. A source joins it when its root cannot be read. Files from offline sources are not claimed (`claimPending(excludingSources:)`).
- **A missing file on an offline source is not a deleted file.** The pipeline returns `.offline` and releases the file (the attempt is not counted) instead of deleting it or marking it failed. The watcher drops events for sources that are not reachable.
- **Polling.** `refreshSources()` rescans every network source, and any source that went offline or came back. It runs every `networkRescanInterval` (15 minutes), and the app also calls it on `NSWorkspace` mount, unmount and wake notifications. Rescans compare size and modification date, so unchanged files are not read.
- **UI and API.** `SourceInfo.isNetworkVolume`; a disconnected share shows "Not connected", not an error, and its indexed files stay searchable. `/v1/sources` adds `network`.

## Consequences

- Changes made on another machine appear within 15 minutes, or at the next mount or wake.
- A share that is rarely connected keeps its index indefinitely. Removing the source is the only way to drop it.
- Files are read over the network for hashing and extraction. Large media is hashed from three 1 MB samples, so the extractor's read dominates.
- The network flag is learned while a share is mounted. After a relaunch with the share disconnected, it shows as an unreadable folder until the share mounts again.
- Remote sources that are not mounted (S3, cloud drives) will need a provider that lists and downloads objects; the offline handling here is the behaviour they must match.
