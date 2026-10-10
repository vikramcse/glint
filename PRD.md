# Glint — PRD: On-Device Multimodal Search for Mac

Oct 10, 2026 · @Vikram Jadhav

## Overview

Glint ("Search anything") is a native Mac app that finds any photo, video moment, voice recording, document or PDF page from a plain-language query, with results on screen in under 150 ms, entirely on device. Search basics are free; a one-time Pro license unlocks video, audio, unlimited libraries and power features.

**Problem.** People remember what something looked like or what was said, not the filename or folder. Spotlight matches names and keywords, Photos only searches the Photos library, and no built-in tool searches a voice memo, a screen recording and a scanned PDF with one query.

**Why now.** [EmbeddingGemma 2](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/) (released 6 Oct 2026, Apache 2.0) maps text, code, images, video and audio into one 768-dimension space in a sub-1B model, so one small on-device index can answer any query across all five media. Apple silicon's unified memory makes a GPU-resident index practical on an 8 GB Mac.

**Our edge** is speed and craft, not the model. Every competitor can use a similar model; few will feel instant and look like Apple built them.

| Alternative | What it covers | Gap we fill |
| --- | --- | --- |
| [Apple Photos](https://support.apple.com/guide/mac-help/mchl35c53342) + Spotlight | Natural-language search inside the Photos library; semantic Spotlight APIs announced for macOS 27 ([report](https://letsdatascience.com/news/apple-rebuilds-search-infrastructure-powering-spotlight-and-b37590b7)) | Folders, drives, voice and PDFs in one query; video moments in any folder; older Macs and regions without Apple Intelligence |
| [Omni](https://github.com/hanxiao/omni-macos) | Free, open-source multimodal search; model weights are CC-BY-NC | Commercial-safe model, consumer polish, curated workflows, support |
| [SCM](https://github.com/allenv0/SCM), [Invenio](https://getinvenio.com/) | Photo and video search only | Documents, PDFs and audio in the same index; native (SCM is Electron) |

The risk this positioning carries: Apple and free tools shrink the gap each year, so Pro value must sit in workflows Apple will not build (see Risks).

## Goals, non-goals and success metrics

Version 1.0 succeeds if search feels instant on a base M1 Mac, finds the right item in the top ten for most real queries, and earns enough one-time sales to fund 1.x updates.

**Goals**

1. **Instant.** Results update as you type; no spinner on any search interaction.
2. **One index, five media.** Photos, videos (to the moment), audio and voice memos, text documents, PDFs (text and page visuals).
3. **Feels like Apple made it.** Standard controls, system materials, keyboard-first, fully accessible.
4. **Private by construction.** No file, query or vector leaves the Mac.
5. **Sustainable.** Free tier that is genuinely useful; Pro that is worth a one-time payment.
6. **Safe to change.** Every change runs tests, retrieval evals and performance checks before merge.

**Non-goals for 1.0**

- Cloud sync, iOS, iPadOS, Windows
- Generated answers or chat over files (candidate for 1.x)
- Shared team indexes and NAS servers (candidate for 2.0)
- Editing, moving or organizing the user's files
- Mac App Store build (sandbox conflicts with broad file access)

**Success metrics** (targets are starting points to confirm in the M0 spike and beta)

| Metric | 1.0 target | Measured by |
| --- | --- | --- |
| Keystroke to updated results, p95, warm, 100k chunks | ≤ 150 ms | Signposts in perf suite on M1 8 GB |
| Hotkey to search panel visible, p95 | ≤ 60 ms | Signposts |
| First useful result after install | ≤ 3 min | Onboarding funnel (opt-in analytics) |
| Recall@10 on golden eval set | ≥ 0.85 overall, ≥ 0.75 per media type | Eval harness |
| Crash-free sessions | ≥ 99.8% | MetricKit |
| Free to Pro conversion within 30 days | 3–5% | License activations ÷ opted-in installs |
| Refund rate | < 3% | Payment provider |

## Users and use cases

The paying user has a large, mixed library outside the Photos app and loses time finding things in it every week.

| Persona | Library | Job to be done | Pays for |
| --- | --- | --- | --- |
| Creator (YouTuber, editor, podcaster) | Footage folders, screen recordings, exported audio, external SSDs | "Find the shot where I hold up the blue mug" and jump to the second | Video moments, external drives, find similar |
| Knowledge worker (consultant, researcher, student) | PDFs, slides, notes, voice memos from meetings | "The deck with the pricing chart for the Acme pitch" | Scanned PDF and slide visuals, voice search |
| Privacy-bound professional (lawyer, therapist, journalist) | Interview recordings, case files, scans | Search confidential material without any upload | On-device guarantee, audio search |
| Everyday Mac user | Screenshots, downloads, camera exports | "That screenshot of the flight confirmation" | Usually stays on Free |

**Core user stories**

- As a user, I press a hotkey, type a description and open the right file without touching the mouse.
- As a creator, I search "crowd cheering at night" and land on the exact moment inside a 40-minute video.
- As a researcher, I search "chart showing revenue by region" and get the PDF page, even when the chart is an image.
- As a professional, I search "when the client mentioned the deadline" and play the voice memo from that point.
- As anyone, I drop a file on Glint and see similar photos, clips or documents.
- As a new user, I get useful results within minutes of installing, while indexing continues in the background.

## Features: Free and Pro

Free covers everyday search of photos, screenshots and documents; Pro is a one-time purchase of $49 (launch price $39) that unlocks video, audio, scale and power features for all 1.x releases on two Macs. Prices are assumptions to test in beta; regional pricing for markets such as India is an open question.

| Capability | Free | Pro |
| --- | --- | --- |
| Global hotkey search panel, keyboard navigation, Quick Look | Yes | Yes |
| Images and screenshots (visual search + on-device OCR text) | Yes | Yes |
| Text documents, Markdown, RTF, Word, code | Yes | Yes |
| PDFs: text search by page | Yes | Yes |
| PDFs and slides: visual page search (charts, scans, diagrams) | No | Yes |
| Indexed items | Up to 10,000 | Unlimited |
| Sources | Up to 3 folders | Unlimited folders, external drives, Apple Photos library |
| Video: search moments, open at timestamp | No | Yes |
| Audio and voice memos: search by sound and speech, play from match | No | Yes |
| Find similar (drop a file to search) | No | Yes |
| Filters and search tokens (kind, date, folder) | Basic | Full, plus saved searches |
| Model choice and quality presets | Default only | Choose model, dimension and speed/quality preset |
| Local API and MCP server for agents | No | Yes |
| Trial | — | 14 days of Pro on first launch, no account needed |

**Gating rules**

- Gating lives in one `Entitlements` type; views and services ask it, never check license state directly.
- Free limits never delete data. Above 10,000 items, indexing pauses with a clear upsell and existing results keep working.
- When a trial ends, video and audio results stay visible but locked, so users see the value they would buy.
- A 1.x license keeps working forever; 2.0 is a paid upgrade at a discount for existing owners.

## Performance budgets

Speed is the product, so every interaction has a budget, measured in CI on an M1 8 GB reference Mac, and a change that breaks one does not merge. Numbers are targets to confirm in the M0 spike.

| Interaction | p50 | p95 |
| --- | --- | --- |
| Cold launch to interactive panel | 250 ms | 400 ms |
| Hotkey to panel visible (app running) | 30 ms | 60 ms |
| Keystroke to keyword results (FTS) | 15 ms | 30 ms |
| Query embedding, text encoder warm | 15 ms | 30 ms |
| Vector scan, 100k chunks at 512 d | 8 ms | 20 ms |
| Keystroke to merged semantic results on screen | 80 ms | 150 ms |
| Thumbnail on screen when scrolling results | 1 frame | 2 frames at 120 Hz |
| Open result (Quick Look or at video timestamp) | 100 ms | 200 ms |
| Idle memory with query encoder loaded | 350 MB | 500 MB |

**How we hit them**

- **Two-phase results.** Keyword matches render on the keystroke; semantic matches merge in when the embedding returns, without moving the row under the cursor.
- **Warm, small query path.** Only the 270M text encoder stays resident (quantized); vision and audio towers load for indexing and unload when idle.
- **Debounce and cancel.** Query embedding starts 40 ms after the last keystroke; any newer keystroke cancels the in-flight task.
- **GPU-resident index.** Vectors sit in one contiguous matrix; a query is a single matrix multiply. Beyond the memory budget, a quantized coarse scan picks candidates that are rescored exactly (a pattern [Omni](https://github.com/hanxiao/omni-macos) shows works on Apple silicon).
- **Indexing yields to search.** The indexer's GPU work goes through a priority gate and shrinks its batch while the user is typing.
- **Precomputed display data.** Thumbnails, keyframes, waveforms and snippets are generated at index time and cached; the results view never decodes a full file.
- **Main thread stays free.** No file, database or model work on the main actor; the UI only receives finished view models.

Indexing throughput budgets (items per minute per media type) are set from the M0 benchmark, then guarded against regression.

## Design and UX

Glint should look like a first-party Apple app: standard SwiftUI controls, system materials, SF Symbols and SF Pro, the current system design language (Liquid Glass on macOS 26 and later), and no custom chrome. When in doubt, do what Photos, Finder and Spotlight do.

**Principles** (from Apple's Human Interface Guidelines)

- **Content first.** Thumbnails, frames and snippets carry the screen; controls recede.
- **Keyboard first, mouse friendly.** Every action has a shortcut and a visible equivalent.
- **Quiet by default.** No badges, banners or upsells during a search; status lives in the menu bar item.
- **Honest state.** Show what is indexed, what is pending and why something is not found.

**Surfaces**

1. **Search panel.** A floating panel summoned by a global hotkey (default ⌥Space, user-configurable). One search field, results grouped by kind (Top hits, Photos, Video moments, Audio, Documents, PDF pages). Arrow keys move, Return opens, Space previews with Quick Look, ⌘Return reveals in Finder, ⌘C copies, and items drag out into any app. Esc dismisses.
2. **Main window.** `NavigationSplitView` with a sidebar (Library by kind, Sources, Saved searches), a results grid or list, and an inspector (preview, metadata, matched moment or page, similar items). Search tokens like Photos and Mail for kind, date and folder filters.
3. **Result types.** Photo: thumbnail with matched OCR words highlighted. Video moment: keyframe, timecode and a mini scrubber that plays from the match. Audio: waveform with the matched window highlighted and inline play. PDF page: page thumbnail with page number and text snippet. Document: title, folder, snippet with highlighted terms.
4. **Menu bar item.** Indexing progress, pause and resume, open window. Disappears from view when idle if the user prefers.
5. **Settings.** Standard Settings window with tabs: General (hotkey, launch at login), Sources (folders, drives, Photos, exclusions), Search (default filters, result grouping), Models (Pro: model, quality preset, storage used), Privacy (analytics opt-in, network activity list, delete index), License.

**Onboarding** (three screens, under a minute)

1. What Glint does, with a 5-second looping demo.
2. Choose sources; suggested folders are pre-selected (Desktop, Documents, Downloads, Screenshots). Permissions are requested just in time, each with a one-line reason; Full Disk Access is optional, with a guided step.
3. Set the hotkey and opt in or out of anonymous analytics. Indexing starts; the first search works on what is already indexed, newest files first.

**Accessibility and polish**

- Every control and result has a VoiceOver label ("Video, Beach trip, moment at 12 minutes 4 seconds").
- Full keyboard access, visible focus rings, respects Reduce Motion, Increase Contrast and Reduce Transparency.
- Light and dark appearance, accent color from system settings.
- Localized from day one through String Catalogs; English at launch.
- Empty, still-indexing, no-results and permission-denied states are each designed, not defaults.

## System architecture

Glint is one Swift process with no Python and no server: a background indexer and an interactive search path share one on-device index, and every replaceable part (model, extractor, store) sits behind a protocol so it can change without touching the rest.

&#91;embedded content: architecture · indexing and search paths\]

The indexer writes and the search path reads; their only shared resources are the store and a GPU priority gate that always favors search. Licensing and telemetry sit beside both and touch neither.

**Modules** (Swift packages; dependencies point inward toward Core)

| Package | Responsibility | Depends on |
| --- | --- | --- |
| `GlintCore` | Domain types (`FileRef`, `Chunk`, `Embedding`, `ModelDescriptor`), protocols, errors | Nothing |
| `GlintExtractors` | One extractor per content type: text, PDF, image, audio, video | Core, Apple frameworks |
| `GlintEmbedding` | `EmbeddingProvider` backends (MLX first, Core ML optional), batching, priority gate | Core |
| `GlintStore` | SQLite (GRDB, WAL) for files, chunks, FTS5 and vector blobs; schema migrations | Core |
| `GlintSearch` | Resident vector matrix, hybrid ranking, filters, grouping by file | Core, Store |
| `GlintIndexer` | Scanner, FSEvents watcher, scheduler, pipeline stages, power and thermal policy | Core, Extractors, Embedding, Store |
| `GlintLicensing` | License verification, activation client, `Entitlements` | Core |
| `GlintTelemetry` | Opt-in event queue and sender, MetricKit hooks | Core |
| `GlintUI` | SwiftUI views and view models | Core, Search, Licensing |
| App target | Composition root: builds the object graph, owns lifecycle | Everything |

**Key protocols** (the extension points)

```swift
public protocol EmbeddingProvider: Sendable {
    var descriptor: ModelDescriptor { get }          // id, version, dims, modalities, license
    func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding]
}

public enum EmbeddingInput: Sendable {
    case text(String), image(CGImage), audio(AudioClip), video(VideoClip)
    case interleaved([EmbeddingInput])
}

public protocol ContentExtractor: Sendable {
    static var contentTypes: Set<UTType> { get }
    func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, Error>
}

public protocol VectorIndex: Sendable {
    func upsert(_ vectors: [StoredVector]) async throws
    func remove(fileID: FileID) async throws
    func search(_ query: Embedding, limit: Int, filter: SearchFilter) async throws -> [ScoredChunk]
}
```

Adding a file type means adding one `ContentExtractor`; adding a model means adding one `EmbeddingProvider`. Neither change touches the UI, the store or the other extractors.

**Indexing pipeline**

1. **Scan.** On first run, walk the chosen sources and write every file's path, size, modification date and type to a `files` table as pending. Takes seconds and needs no model, so progress shows immediately.
2. **Watch.** FSEvents reports changes; on launch, a fast re-scan catches anything missed while the app was closed.
3. **Schedule.** A priority queue orders work: recently modified documents and images first, audio next, video last. Pauses on battery below 20%, in Low Power Mode or at serious thermal state.
4. **Extract.** A concurrent CPU stage produces chunks (table below) plus display data (thumbnails, keyframes, waveforms, snippets).
5. **Embed.** A single GPU actor batches chunks across files and yields to the search path through a priority gate.
6. **Store.** One writer commits a file's chunks and vectors in one transaction; only then is the file marked done, so a crash or quit loses nothing.

A content hash per file maps copies, moves and touched-but-unchanged files to vectors already stored, so a re-save or a folder move never re-embeds.

| Content | Extraction | Unit embedded | Shown in results |
| --- | --- | --- | --- |
| Text, Markdown, RTF, Word, code | Plain text, \~512-token chunks with 64-token overlap | Text chunk | Snippet with highlights |
| PDF | PDFKit text per page; page rendered to an image | Text chunks per page + one page image (Pro) | Page thumbnail, page number |
| Images, screenshots | ImageIO downscale; Vision OCR text into keyword index | One image vector | Thumbnail, OCR highlights |
| Audio, voice memos | AVFoundation decode to 16 kHz mono; fixed windows with overlap; optional on-device transcript into keyword index | One vector per window | Waveform, timestamp |
| Video | Shot boundaries or fixed clips sampled at 1 frame per second; audio track handled as audio | One vector per clip | Keyframe, timecode |

**Storage and search**

- SQLite is the durable store: `files`, `chunks`, an FTS5 table for keyword and OCR text, and vectors as half-precision blobs tagged with the model and dimension that produced them.
- At launch, vectors load into one contiguous GPU-resident matrix. Search is exact cosine similarity while the index fits the memory budget; beyond it, a quantized coarse scan selects candidates that are rescored exactly.
- Ranking fuses vector and keyword results with reciprocal rank fusion, collapses to the best chunk per file, applies filters, and adds a small recency boost.
- Search runs in its own actor and never waits on the indexer's database writer.

## Model strategy

EmbeddingGemma 2 is the default model because it is commercially licensed (Apache 2.0), small, and covers all five media in one space; the app treats it as one replaceable provider, not a dependency baked into the code.

**Why EmbeddingGemma 2** ([developer guide](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/))

- Modular towers from one checkpoint: 270M parameters for text and code, 440M with vision, 570M with audio, 740M for everything, all in the same vector space.
- A query embedded with the 270M text-only setup matches documents embedded with the full model, so the search path stays small and fast.
- Matryoshka dimensions: 768 down to 512, 256 or 128. Default **512**, which the guide recommends for multimodal recall; 256 is a storage-saving preset to validate on our evals.
- Task prompts: `SearchQuery` for queries, `Document` for text chunks; media passed without a prompt.
- Video sampled at 1 frame per second; audio expected at 16 kHz mono; 8,192-token shared input window.

**Runtime**

- Primary: a native MLX-Swift port of the encoders, running in process on the GPU. The guide lists MLX support, but it does not say whether the vision and audio towers are covered, so the M0 spike confirms this first.
- Fallback: convert towers to Core ML (also lets the Neural Engine take load), or port only the missing towers.
- Quantized weight variants (8-bit, 4-bit) ship only if the eval suite shows less than a 1-point drop in Recall@10.
- Parity gate: Swift outputs must match the Python reference at cosine ≥ 0.999 on fixed fixtures before any model build ships.

**Pluggable models** (Pro: user-selectable)

- Every model ships as a `ModelDescriptor`: id, version, dimensions, supported media, license, download size, checksum.
- Every stored vector records the model id and dimension that produced it. Spaces never mix.
- Switching model builds a new space in the background while the old one keeps serving; the switch is atomic when the new space finishes, and the old one is deleted.
- Only models with a license that allows commercial distribution ship in the app. That excludes, for example, CC-BY-NC weights such as the model Omni uses.
- Candidate additions after 1.0: a larger, higher-quality multimodal model for M-Pro and M-Max Macs; Apple's on-device semantic search APIs (announced for macOS 27) as an optional text provider.

**Delivery.** Weights download once at onboarding from our CDN, checksum-verified, resumable, with clear size shown before download. The app works fully offline afterwards.

## Licensing and payments

A Pro license is a signed token the app verifies offline; the server is only needed to buy, activate and deactivate, so search never stops because a server is down.

**Purchase.** A merchant of record (Paddle or Lemon Squeezy, decided in M3) handles checkout, global sales tax including India GST, receipts and refunds. Checkout opens in the browser from the app's Upgrade sheet; a deep link (`glint://activate?key=…`) returns the key to the app.

**License token**

- Ed25519-signed payload: license id, product, major version (1), seat limit (2), issue date, buyer email hash.
- The public key is compiled into the app; the private key never leaves the license server.
- Verification is local and takes under 1 ms.

**Activation flow**

1. User pastes or deep-links a key.
2. App sends the key and an install id (a random UUID kept in the Keychain, not a hardware serial) to the license server.
3. Server checks seat count, records the device, returns a signed activation token.
4. App stores the token in the Keychain and unlocks Pro immediately.
5. Deactivation from Settings frees the seat; buyers can also free seats from a small web page.

**Rules**

- After activation, Pro works offline indefinitely. The app re-validates opportunistically (at most weekly) and ignores network failures.
- Refunded or charged-back licenses land on a revocation list the app fetches during re-validation.
- Trial: 14 days of Pro, tracked locally. Light anti-tamper only; heavy DRM costs more in support than it saves in piracy.
- License server: a small serverless service (for example a Cloudflare Worker with a database) or the merchant's own license API, whichever M3 shows to be simpler. It stores license, device and activation rows only.
- All license states (none, trial, trial expired, active, revoked, seat limit reached) have designed UI and unit tests.

## Analytics

Analytics are opt-in, anonymous and limited to about ten events, enough to see whether onboarding works, search is fast and Pro converts, and never enough to learn what a user searched for or owns.

**Never collected:** query text, file names, paths, file contents, thumbnails, vectors, IP-derived location, or a persistent cross-app identifier.

| Event | Properties (all bucketed) | Answers |
| --- | --- | --- |
| `app_launched` | App version, macOS version, Mac chip family, RAM bucket | Who runs it, on what hardware |
| `onboarding_completed` | Number of sources, duration bucket | Does onboarding work |
| `first_search` | Minutes since install bucket | Time to first value |
| `index_progress` (daily) | Items per media type bucket, pending bucket | Library shape, indexing health |
| `search_performed` (sampled 10%) | Latency bucket, result count bucket, media types returned | Is search fast and useful |
| `result_opened` | Rank bucket, media type | Ranking quality in the wild |
| `paywall_viewed` | Trigger (limit, locked result, menu) | What drives upgrades |
| `trial_started`, `license_activated` | — | Conversion funnel |

**Implementation**

- A `TelemetryClient` protocol with two implementations: a no-op (default until the user opts in) and a sender to a privacy-focused service such as TelemetryDeck or our own small endpoint.
- Events queue locally and send in one batch at most once a day; the payload is visible to the user in Settings > Privacy.
- An anonymous id rotates every 90 days.
- Crash, hang and launch-time diagnostics come from Apple's MetricKit, which needs no extra tracking.
- One weekly dashboard: installs, onboarding completion, time to first search, p95 search latency by chip, opens per search, trial to paid conversion.

## Engineering standards

The codebase should read like a well-kept Apple sample project: small types with one job, explicit dependencies, and rules a linter or CI enforces rather than rules people remember.

**Language and frameworks**

- Swift 6 language mode with strict concurrency checking; zero warnings policy.
- SwiftUI for all views; AppKit only where SwiftUI cannot do the job (floating panel, global hotkey, Quick Look panel), each wrapped in one small type.
- Actors for shared mutable state (indexer queue, GPU gate, store writer); `Sendable` value types everywhere else.
- Observation (`@Observable`) for view models; no Combine in new code.

**Structure**

- Dependencies flow inward to `GlintCore`; packages never import each other sideways except as listed in the module table. A CI script fails the build on a forbidden import.
- One composition root in the app target; no singletons and no global state elsewhere. Every service takes its dependencies in its initializer, so tests swap in fakes.
- Features are added by conforming to a protocol (new extractor, new model, new telemetry sink), not by adding cases to a central switch.

**Code rules**

- No force unwraps or `try!` outside tests; typed errors per module with user-facing messages mapped in one place.
- Logging through `os.Logger` with privacy annotations (paths and queries marked private); performance signposts on every budgeted path.
- swift-format and SwiftLint in CI; functions over \~40 lines or files over \~400 lines need a reason in review.
- Public APIs documented with DocC comments; significant decisions recorded as short ADRs in the repo.

**Definition of done for a pull request**

- [ ] Unit tests for new logic; integration test if it crosses a package boundary
- [ ] Retrieval evals and performance budgets pass in CI
- [ ] Light, dark, VoiceOver and keyboard paths checked for UI changes
- [ ] Strings in the String Catalog; no hard-coded user-facing text
- [ ] No new third-party dependency without an ADR

## Tests and evals

No change merges unless unit tests, integration tests, retrieval evals and performance budgets all pass; retrieval quality and speed are tested like features, because they are the product.

| Layer | What it covers | Tooling | Runs |
| --- | --- | --- | --- |
| Unit | Chunkers, hashing, ranking fusion, filters, entitlements, license verification, telemetry redaction | Swift Testing | Every push, < 60 s |
| Model parity | Swift encoders vs Python reference on fixed text, image, audio, video fixtures; cosine ≥ 0.999, identical token ids | Swift Testing + generated fixtures | Every push touching `GlintEmbedding` |
| Integration | Index a fixture corpus end to end; edits, moves, renames, deletes, crash mid-transaction, relaunch catch-up | Swift Testing, temp directories | Every push |
| Retrieval evals | Golden query set scored for Recall@10, MRR and nDCG@10, overall and per media type | Custom eval harness (CLI) | Every pull request, full set nightly |
| Performance | Every budget in the Performance section; memory; indexing throughput per media type | XCTest metrics + signposts on reference Macs | Every pull request (core set), nightly (full) |
| UI | Onboarding, search panel, open result, upgrade and activation flows | XCUITest | Every pull request |
| Snapshot | Key views in light, dark, large text and increased contrast | Snapshot testing library | Every pull request |
| Robustness | Corrupt PDFs, zero-byte files, huge files, odd encodings, files vanishing mid-read | Fuzz corpus | Nightly |
| Migration | Database upgrade from every shipped schema version | Archived fixture databases | Every push touching `GlintStore` |
| Licensing | Valid, tampered, expired, revoked tokens; clock changes; offline activation | Swift Testing | Every push |

**Retrieval eval set**

- A fixed corpus we own or have licensed: about 2,000 photos and screenshots, 50 videos, 100 audio files, 300 PDFs and 500 text documents, mirroring the personas' libraries.
- About 300 queries written by people who did not build the system, each with graded relevant items (exact match, relevant, not relevant), including hard negatives and cross-media queries ("the receipt from the hotel in Goa", "when she laughs at the end").
- The harness indexes the corpus with the candidate build, runs every query, and writes a report comparing it to the last `main` build.
- Gates: no metric may drop more than 1 point overall or 2 points for any media type, and no query in the "must pass" set (about 50 critical queries) may fall out of the top 10.
- Every bug report about a missed result becomes a new eval query once fixed.

**CI setup**

- Hosted Apple silicon runners for build, unit, integration, UI and snapshot tests.
- A dedicated M1 8 GB Mac mini (the floor) and one newer Mac run performance and full evals, so numbers are comparable night to night.
- Release builds also run a signed, notarized install-and-launch smoke test.

## Privacy, security and distribution

Glint makes exactly four kinds of network request, each listed in Settings > Privacy: the one-time model download, update checks, license activation and re-validation, and opt-in analytics. Nothing about the user's files ever leaves the Mac.

**Data on disk**

- Index, thumbnails and caches live in `~/Library/Application Support/Glint`, protected by the user's FileVault and account permissions.
- "Delete index" removes everything Glint derived; uninstall instructions cover the same folder.
- Exclusion rules (folders, file types, hidden files) apply before extraction, not after.

**Permissions**

- Folder access through user-chosen folders with security-scoped bookmarks; Full Disk Access is optional and explained.
- Apple Photos library through PhotoKit (Pro), reading only items already on the Mac; iCloud-only originals are skipped, not downloaded.
- No microphone, camera, contacts or location access.

**Distribution**

- Direct download: Developer ID signed, notarized, hardened runtime, Apple silicon only, macOS 15 or later (open question).
- Updates through Sparkle with EdDSA-signed appcasts; release notes shown in app.
- Not in the Mac App Store at 1.0, because sandboxing conflicts with indexing arbitrary folders and drives; revisit a sandboxed "Lite" later.

## Milestones

The plan reaches a public 1.0 in about 20 weeks, and each phase ends at a gate that must pass before the next starts; M0 exists to kill or confirm the riskiest assumption (a fast native port of the model) in two weeks.

&#91;embedded content: roadmap · 5 phases, 4 gates\]

After 1.0: local API and MCP server, model choice in Settings, creator export to Final Cut and Premiere, then shared indexes for small teams as the 2.0 candidate.

## Risks and open questions

The largest risk is commercial, not technical: Apple and free tools keep closing the gap, so Pro must stay ahead on speed, video and audio, and workflows Apple will not build.

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Apple ships semantic Spotlight and richer Photos search (macOS 27) | Free tier loses its reason to exist | Lead with folders, drives, video moments, audio and cross-media search; invest in creator and professional workflows |
| Free open-source competitors (Omni, SCM) | Price pressure | Win on speed, polish, commercial-safe model, support; keep price one-time and fair |
| MLX-Swift port of vision and audio towers takes longer than planned | Delays M2 | Spike in M0; Core ML fallback; ship text, PDF and image first |
| Video indexing is slow on base Macs | Poor first impression for creators | Index video last, show honest progress, plugged-in-only option, quality presets |
| Retrieval quality weak on niche content | Users lose trust | Golden eval set from real persona libraries, hybrid keyword search, missed-result reports become evals |
| Piracy of a one-time license | Lost revenue | Accept some; keep activation simple and fair rather than adding DRM |
| Name "Glint" is already used by several small Mac apps and by Microsoft Viva Glint | Confusion, trademark issue | Ship under a distinct full name such as "Glint Search"; clear trademark, domain and App Store listing before public beta |

**Open questions**

- [ ] Glint or Glint Search as the full name, plus trademark and domain check
- [ ] Minimum macOS version: 15 or 14 (14 widens reach, adds testing cost)
- [ ] Final price, launch discount and regional pricing (for example India)
- [ ] Paddle or Lemon Squeezy, and build or buy the license server
- [ ] Free tier limits: 10,000 items and 3 folders, or a different line
- [ ] Whether on-device transcripts of audio and video are Free (keyword only) or Pro
- [ ] Which creator workflow ships first after 1.0: Final Cut and Premiere export, or find similar across drives

**Sources**

- [EmbeddingGemma 2: The Developer Guide](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/), Google Developers Blog, 6 Oct 2026
- [Omni (omni-macos)](https://github.com/hanxiao/omni-macos) and its [paper](https://arxiv.org/abs/2608.05543)
- [Use Apple Intelligence in Photos on Mac](https://support.apple.com/guide/mac-help/mchl35c53342), Apple Support
- [Apple rebuilds search infrastructure powering Spotlight and Mail](https://letsdatascience.com/news/apple-rebuilds-search-infrastructure-powering-spotlight-and-b37590b7)
- [SCM](https://github.com/allenv0/SCM), [Invenio](https://getinvenio.com/)
