# ADR 0003: System SQLite through a small wrapper instead of GRDB

**Status:** Accepted · 2026-10-10

## Context

The original design named SQLite (GRDB, WAL) for files, chunks, FTS5 and vector blobs. The engineering standards also say no new third-party dependency without an ADR.

## Decision

Use the SQLite that ships with macOS (FTS5 included) through `GlintStore/SQLite.swift`, about 150 lines: one connection per actor, cached prepared statements, typed bindings, immediate transactions. `IndexWriter` is the only writer; `IndexReader` is a separate read-only WAL connection, so the search path never waits on the indexer.

## Consequences

- Zero third-party dependencies in the shipping app; builds work offline.
- We own migrations (`Schema.swift`, `PRAGMA user_version`) and test upgrades from archived databases of every shipped version (`Tests/GlintStoreTests/Fixtures`).
- If query-building needs grow, revisit GRDB; the store's public API would not change.
