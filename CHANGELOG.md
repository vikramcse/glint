# Changelog

All notable changes to Glint are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- A crash when a folder watcher was released while file-system events were arriving.
- Photos no longer show stray OCR snippets such as "•–" when they contain no words.
- Cached thumbnails show immediately instead of flashing the file icon.

## [1.0.0]

First public release.

- One search for images, video, audio, PDFs and text documents, plus the Apple Photos library, using EmbeddingGemma 2 on the GPU.
- Hybrid keyword and semantic search with per-library calibration, from a Spotlight-style panel (<kbd>⌥</kbd> <kbd>Space</kbd>) and a main window.
- PDFs open at the matched page; audio and video play from the matched moment.
- People: faces in photos and videos grouped by person, with naming and merging.
- Sources: local folders, external drives, network shares and S3-compatible buckets.
- An opt-in local API and the `glint-mcp` server for AI agents.
