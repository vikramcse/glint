# ADR 0004: GPU-resident half-precision matrix and a bounded keyword ranking window

**Status:** Accepted · 2026-10-10

## Context

Budgets (p95 on an M1 8 GB): vector scan of 100k chunks at 512 d ≤ 20 ms, keystroke to keyword results ≤ 30 ms, keystroke to merged results ≤ 150 ms.

## Decision

**Vectors.** `FlatVectorIndex` keeps every vector of the active space in one contiguous `Float16` matrix allocated as a shared-storage `MTLBuffer`, so the CPU writes rows and the GPU reads them with no copies. A query is one Metal kernel (one thread per row, `half4` loads, float accumulation) and a bounded top-k heap. Rows are removed by swapping in the last row. A CPU path (vImage half→float conversion plus `vDSP_mmul`) is the fallback and the test oracle. 100k × 512 halves is about 100 MB, inside the 500 MB idle budget, so the quantized coarse scan is deferred until libraries exceed the memory budget.

**Keywords.** BM25 ranks at most the newest 5,000 FTS matches (`IndexReader.rankingWindow`), selected with a rowid range so FTS5 stays on its fast path (an `IN` list was 1,000× slower). Everything still matches; only the ranking window is capped. Without this, a two-letter prefix on a large library ranked every match (113 ms p95 in the budget suite).

## Measured (M5, release, `GLINT_PERF=1`)

| Budget | p95 | Target |
| --- | --- | --- |
| Vector scan, 100k × 512 | 2.3 ms | 20 ms |
| Query embedding, warm | 1.7 ms | 30 ms |
| Keystroke → keyword results, 100k chunks | 13 ms | 30 ms |
| Keystroke → merged results, 100k chunks | 26 ms | 150 ms |

The M1 8 GB reference Mac in CI is the gate; these numbers are headroom, not proof.
