# ADR 0006: Streaming indexing pipeline in Swift, with an automatic OCR policy

**Status:** Accepted · 2026-10-10

## Context

Indexing time goes almost entirely into Apple frameworks (Vision OCR, ImageIO, PDFKit, AVFoundation) and the embedding model on the GPU or Neural Engine, not into Glint's own code. Rust would wrap the same calls through FFI without making them faster. Swift stays.

`glint-eval bench` measured the original pipeline and found three problems:

- The indexer claimed a batch of files and waited for all of them, so one long video stalled everything behind it.
- Each file was embedded on its own, so files never shared a batch.
- Every image went through accurate OCR with language correction and automatic language detection, including photos with no text.

## Decision

**Pipeline** (`GlintIndexer`)

- **Worker pool.** Workers take the next file as soon as they finish one. A small prefetch queue backs onto the store-based queue: each claim still counts as an attempt, and files already in flight are excluded from claims.
- **Streaming per file.** Chunks are embedded in windows while extraction continues, with at most `embeddingWindowsInFlight` windows per file. A long video never holds all of its frames in memory.
- **Embedding lanes (`EmbeddingBatcher`).** Windows from different files are packed into one model call, up to `embeddingBatchSize` inputs, waiting at most `embeddingBatchWait` for more. Up to `embeddingLanes` calls run at once. Every call waits for the `PriorityGate` and uses smaller batches while the user types.
- **Group commit (`CommitBatcher`).** An idle writer commits a file at once. Files that finish during a commit go into the next transaction together. Each file is written whole, so a file is either fully indexed or still pending.
- **Hashing** runs on a GCD queue, never on the cooperative pool.
- **Power and heat.** On battery, or at "fair" thermal state, workers and OCR lanes drop to half (`constrainedWidthFactor`). Glint still pauses at serious thermal state, in Low Power Mode, and below 20% battery.

**OCR** (`ExtractionOptions.ocrLevel = .automatic`, the default)

- **Camera photos** (EXIF exposure, lens or make) run a 1–3 ms text check. Accurate recognition runs only when the check finds text.
- **Screens and other images larger than the preview** are decoded once at `ocrMaxPixel` (2048 px), and the preview and thumbnail are scaled from that. The fast recognizer runs only when the text detector finds text; it is reliable at 2048 px but misses small UI text at 1024 px.
- **Scanned PDF pages** are rendered at 2048 px for the fast recognizer.
- **Why fast recognition at 2048 px:** it matched accurate recognition on 99.96% of words (2,688 words of screenshot text), at 27 ms against 149–421 ms. At 1024 px it got only 27% of words right.
- **Language correction** is off for crisp text. It cost 2.5× and changed no words.
- **The OCR lane** stays at 2. Accurate OCR doesn't speed up beyond two concurrent requests.

## Measured

Apple M5, release build, `glint-eval bench` on its generated corpus (40 camera photos, 4 of them with a sign, 40 Retina screenshots, 12 ten-page PDFs, 120 docs, 6 one-to-three-minute audio files, 4 1080p videos). Units are items per minute.

| Kind | Before, pipeline only | After, pipeline only | Before, built-in model | After, built-in model |
| --- | --- | --- | --- | --- |
| Photos | 280 | 2,800–3,700 | 634 | 3,176 |
| Screenshots | 141 | 1,880–3,165 | 162 | 1,656 |
| PDFs | 4,362 | 4,100–5,600 | 102 | 96 |
| Docs | 155,000 | 74,000 | 412 | 399 |
| Audio | 2,693 | 2,320 | 147 | 114 |
| Video | 235 | 210 | 126 | 82–129 |
| All 222 files together | 689 | 5,113 | 274 | 383 (2 lanes), 441 (4 lanes) |

How to read the table:

- **"Pipeline only"** uses `PipelineEmbeddingProvider`, so it measures Glint's own work.
- **Text is checked after every run:** `text✓` counts files whose extracted text contains a known word. Speedups never come from skipping OCR.
- **Docs, PDFs and audio with the built-in model** are limited by that model's single `NLEmbedding` actor, which embeds text one input at a time. The pipeline can't fix that, and EmbeddingGemma 2 replaces it.
- **The pipeline-only docs row** falls from 155,000 to 74,000/min, but both runs take under 0.1 s, which is within noise.

`IndexingThroughputTests` (run with `GLINT_PERF=1`) sets items-per-minute floors per media kind for the M1 8 GB reference Mac.

## Consequences

- A batched GPU model (EmbeddingGemma 2 on MLX) gets full cross-file batches. Tune `embeddingBatchSize` and `embeddingLanes` for it with `glint-eval bench --model …`.
- Text in camera photos is found only when the 1024 px text check sees it, so very small scene text can be missed.
