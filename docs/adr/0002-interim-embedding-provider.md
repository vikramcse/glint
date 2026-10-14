# ADR 0002: Ship behind an interim on-device provider until the EmbeddingGemma 2 port passes M0

**Status:** Accepted · 2026-10-10

## Context

EmbeddingGemma 2 (released 6 Oct 2026) is the 1.0 default model. The plan's riskiest assumption is a fast MLX-Swift port of its towers, which the M0 spike must confirm with a parity gate (cosine ≥ 0.999 against the Python reference). Weights are not yet on our CDN and the vision and audio towers' MLX coverage is unconfirmed.

## Decision

Everything above the `EmbeddingProvider` protocol is built and tested now. The shipping provider today is `AppleOnDeviceEmbeddingProvider`, built only from macOS frameworks:

- Images, video frames and audio are described with words by Vision scene classification and SoundAnalysis sound classification (plus OCR text fused in by the indexer).
- All inputs, including queries, are embedded by `NLEmbedding.sentenceEmbedding(for: .english)` (512 d), giving one shared space for all five media with no download.
- Vision and SoundAnalysis run on a GCD queue, never on Swift's cooperative pool (synchronous Vision calls there can deadlock).

`ModelCatalog.embeddingGemma2` describes the target model (768/512/256/128 d, Apache-2.0); it is listed as unavailable until its provider lands.

## Consequences

- Swapping in EmbeddingGemma 2 is one new `EmbeddingProvider` conformance plus a catalog flag. Vectors are tagged with `descriptor.space` (id, version, dimension); on launch the indexer re-queues files from any other space, so spaces never mix.
- Quality is lower than a native multimodal model, especially for visual content without recognizable scene labels. The sample eval (Recall@10 0.96) is a floor, not the 1.0 target; the persona corpus eval gates the model switch.
- English-only semantic matching for now; keyword search is language-neutral.
