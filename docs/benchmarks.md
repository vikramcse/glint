# Benchmarks

All numbers come from the harnesses in this repository; [development.md](development.md) has the commands to reproduce them.

## Search latency

Measured on an M5 in release, against budgets set for an M1 with 8 GB. Reproduce on your Mac with:

```sh
GLINT_PERF=1 swift test -c release --filter GlintPerformanceTests
```

| Path | p95 | Budget |
| --- | ---: | ---: |
| Vector scan, 100k × 512 | 2.3 ms | 20 ms |
| Query embedding, warm | 8.0 ms | 30 ms |
| Keystroke → keyword results, 100k chunks | 13 ms | 30 ms |
| Keystroke → merged results, 100k chunks | 26 ms | 150 ms |

## Retrieval quality

`glint-eval` indexes a corpus with the real extractors and model, then scores graded queries. Current EmbeddingGemma 2 baselines (512 d, `Evals/`):

| Benchmark | Files | What it tests | Recall@10 | MRR | nDCG@10 |
| --- | ---: | --- | ---: | ---: | ---: |
| Sample | 12 | Screenshots, receipts, docs, PDFs | 1.000 | 1.000 | 0.997 |
| SciFact | 5,183 | Scientific claim → abstract | 0.925 | 0.810 | 0.832 |
| COCO | 600 | Photo captions and categories | 0.847 | 0.885 | 0.834 |
| COCO trains | 244 | One themed trip, searched for details | 0.784 | 0.713 | 0.700 |
| Mixed | 1,800 | Photos and papers in one index | 0.947 | 0.850 | 0.868 |
| Media | 1,200 | Photos, papers, video and audio in one index | 0.729 | 0.678 | 0.680 |

Per kind on the media benchmark: documents 0.988, images 0.883, video 0.850, **audio 0.138** Recall@10. Searching sound by description is the weakest area today; see [Project status](../README.md#project-status).

Changes are gated: no metric may drop more than 1 point overall or 2 points for any media type, and no must-pass query may leave the top 10.

## Face grouping

`glint-eval faces` runs the real face pipeline on [Labeled Faces in the Wild](https://vis-www.cs.umass.edu/lfw/): 150 people with 8 photos each, hidden among 2,000 strangers seen once.

| Measure | Result |
| --- | ---: |
| Faces found | 3,200 of 3,200 photos |
| Time per photo (detect, align, identify; M5) | 8 ms |
| Same person, 5th-percentile similarity | 0.50 |
| Different people, 99.9th-percentile similarity | 0.37 |
| Grouping precision (faces grouped together are one person) | 0.990 |
| Grouping recall (one person's faces end up together) | 0.975 |

## Indexing throughput

With EmbeddingGemma 2 on an M5 (Release), in items per minute: photos 312, screenshots 297, documents 1,119, PDFs 27 (text plus a visual embedding per page), audio 63, video 13. The model is now the cost; Glint's own stages (hash, extract, commit) are noise. See [ADR 0008](adr/0008-indexing-pipeline.md) for the full breakdown.

