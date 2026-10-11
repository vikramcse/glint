# ADR 0006: EmbeddingGemma 2 on MLX-Swift, built with Xcode

**Status:** Accepted · 2026-10-10 · supersedes the interim default of ADR 0002

## Context

EmbeddingGemma 2 (Apache-2.0, 6 Oct 2026) maps text, images, video and audio into one 768-d space. The PRD makes it the default model and requires a native Swift runtime with a parity gate (cosine ≥ 0.999 against the Python reference, identical token ids).

## Decision

- **Runtime:** [mlx-swift](https://github.com/ml-explore/mlx-swift) 0.32 (Apple, MIT). New dependency, approved here.
- **Tokenizer:** originally [swift-transformers](https://github.com/huggingface/swift-transformers) `Tokenizers` 1.3. Replaced (2026-10-11) by `EG2Tokenizer`, a compact BPE reading `tokenizer.json`: swift-transformers held ~150 MB for the 262k vocabulary and 515k merges, and keyed them by Swift `String`, which equates canonically equivalent characters (Kelvin sign and K) and missed a space before a combining mark. The drift risk that kept us off our own BPE is covered by `EG2TokenizerParityTests`: 42 hard cases against Hugging Face's Rust tokenizer, and a 30k-text corpus (sources, COCO captions, random Unicode) with 0 mismatches against it. swift-transformers remains a test-only dependency.
- **Port** (`Sources/GlintEmbedding/EmbeddingGemma2/`):
  - Text encoder, processor, image/audio preprocessing and the audio conformer: ported from mlx-vlm's `embedding_gemma2` and `gemma4` modules (MIT).
  - Vision tower: adapted from mlx-swift-lm's Swift Gemma 4 (MIT).
  - Pillow's bicubic resampler is reimplemented bit-exactly so image pixels match the reference.
- **Checkpoint:** `mlx-community/embeddinggemma-2-bf16` (1.49 GB, Google source revision 914f7f8), downloaded once and checksum-verified (see ModelStore).
- **Default output: 512 d.** Matryoshka-truncated and re-normalized, per the model guide. 768/256 are Pro presets.
- **Text path:** compiled with `MLX.compile` and padded to length buckets, so fused graphs are reused.
- **Build:** MLX's Metal kernels cannot be built by `swift build`. Apps, model tests and benchmarks build with `xcodebuild` (Release for anything timed — Debug MLX is 3–4× slower). The Metal Toolchain component must be installed once: `xcodebuild -downloadComponent MetalToolchain`.

## Parity gate (Tests/GlintEmbeddingTests/EmbeddingGemma2ParityTests.swift, M5, Release)

| Check | Result |
| --- | --- |
| Token ids, 5 texts incl. CJK/emoji/code | identical |
| Text embeddings | cosine 0.99997–1.0 |
| Image preprocessing (resize, patches, positions) | identical pixels |
| Photo / document / photo + text, end to end | 0.99998 / 0.99981 / 0.99997 |
| Audio (features + conformer) | 0.99995 |

## Measured (M5, Release)

Query embedding p50 6.8 ms / p95 8.0 ms (budget 30 ms on M1). Image 120–180 ms, 10 s audio window 68 ms, 5 s video clip (5 frames) 148 ms.

## Consequences

- One space for all media; the Apple descriptor provider (ADR 0002) remains only as a fallback while weights download or if loading fails.
- The text tower in bf16 is ~0.5 GB resident; the vision/audio towers load for indexing and unload when idle. Quantizing the resident text tower to 8-bit is gated on the eval suite (< 1 point Recall@10 drop).
- Video parity is covered through the shared vision path (frames use the image pipeline at 140 soft tokens); a decoded-video fixture is a follow-up.
