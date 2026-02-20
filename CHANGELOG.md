# Changelog

## [1.0.0] - 2026-02-20

### Added
- **Academic Search (OpenAlex integration)** — 5 new tools for external literature search:
  - `academic_search` — keyword search across 250M+ papers
  - `academic_get_paper` — full metadata by DOI (abstract, authors, citations, open access)
  - `academic_get_citations` — forward citation tracking
  - `academic_get_references` — backward reference tracking
  - `academic_search_author` — search by author name
- **Enhanced Zotero tools** — 3 new tools:
  - `zotero_get_items_in_collection` — list items in a specific collection
  - `zotero_search_by_doi` — find Zotero items by DOI
  - `zotero_get_attachments` — get PDF attachment file paths
- **Embedding persistence** — semantic search index now saved to SQLite (`~/.che-zotero-mcp/embeddings.sqlite`), survives server restarts
- `AcademicSearchClient.swift` — new OpenAlex API client with abstract reconstruction from inverted index

### Changed
- Version bump: 0.1.0 → 1.0.0
- `zotero_build_index` now auto-saves embeddings to disk after building
- Embeddings auto-load from disk on server startup
- Updated mlx-swift dependency: 0.30.3 → 0.30.6

### Fixed
- N/A

## [0.1.0] - 2026-02-10

### Added
- Initial project structure
- MCP server with 7 tool definitions
- ZoteroReader stub (SQLite read-only access)
- EmbeddingManager stub (MLXEmbedders integration)
