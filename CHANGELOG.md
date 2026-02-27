# Changelog

## [1.3.0] - 2026-02-27

### Added
- **Write operation idempotency** — all write tools now check-before-write to prevent duplicates:
  - `zotero_add_item_by_doi` — searches Zotero Web API by DOI before creating
  - `zotero_create_item` — searches by DOI (if provided) before creating
  - `zotero_create_collection` — searches by name + parent before creating
  - `import_publications_to_zotero` — per-DOI dedup via Web API during batch import
- **`zotero_delete_item`** — new tool to permanently delete an item by key (via Web API)
- `searchItemByDOI()` — new ZoteroWebAPI method for DOI-based item search
- `findCollection()` — new ZoteroWebAPI method for collection search by name + parent

### Changed
- Version bump: 1.2.1 → 1.3.0
- Server.swift split into 5 files (586 + 190 + 293 + 182 + 53 lines) for maintainability
- Tool count: 23 → 24 (19 read + 5 write when API key is set)
- `addItemByDOI()` return type now includes `isDuplicate` flag
- `createCollection()` return type now includes `isDuplicate` flag

### Fixed
- Duplicate items created when AI agents retry write operations (root cause of manual cleanup needed in v1.2.0)

## [1.2.1] - 2026-02-26

### Added
- **Data Sources documentation** — new README section documenting which tools connect to Local SQLite vs Zotero Web API vs OpenAlex API, with failure modes and troubleshooting tips

### Changed
- Version bump: 1.2.0 → 1.2.1

### Fixed
- N/A

## [1.2.0] - 2026-02-26

### Added
- **ORCID integration** — new ORCID Public API client (`OrcidClient.swift`):
  - `orcid_get_publications` — fetch public publications from any ORCID ID
- **Multi-source publication import** — batch import to Zotero from multiple sources:
  - `import_publications_to_zotero` — import from ORCID, OpenAlex ORCID, or manual DOI list
  - Supports dry-run preview, skip-existing dedup, collection assignment, and tagging
- **Universal DOI resolver** — cascading metadata resolution (`DOIResolver.swift`):
  - OpenAlex → doi.org content negotiation → Airiti DOI
  - Covers all 12 global DOI Registration Agencies (Crossref, DataCite, mEDRA, Airiti, JaLC, KISTI, etc.)
  - CSL-JSON parser handles Western and CJK author name formats
- `OrcidClient.swift` — ORCID Public API v3.0 client (free, no auth)
- `DOIResolver.swift` — universal DOI metadata resolver with cascading fallback
- `AcademicSearchClient.getWorksByOrcid()` — OpenAlex author search by ORCID ID

### Changed
- Version bump: 1.1.0 → 1.2.0
- `zotero_add_item_by_doi` now uses DOIResolver (supports Airiti and all DOI RAs, not just OpenAlex)
- Tool count: 21 → 23 (19 read + 4 write when API key is set)

### Fixed
- N/A

## [1.1.0] - 2026-02-24

### Added
- **Zotero Web API write operations** — 4 new tools (require `ZOTERO_API_KEY`):
  - `zotero_create_collection` — create collections in Zotero
  - `zotero_add_item_by_doi` — add paper by DOI with auto-fill from OpenAlex
  - `zotero_create_item` — create item with explicit fields
  - `zotero_add_to_collection` — add existing item to a collection
- **Notes & Annotations reading** — 2 new tools:
  - `zotero_get_notes` — read notes attached to items (HTML stripped to plain text)
  - `zotero_get_annotations` — read PDF highlights, underlines, and comments
- `ZoteroWebAPI.swift` — Zotero Web API v3 client for write operations
- `getItemCollectionKeys()` — get collection keys for an item (for API updates)
- Unit tests: 29 tests covering ZoteroReader, AcademicSearchClient, EmbeddingManager, ZoteroWebAPI

### Changed
- Version bump: 1.0.0 → 1.1.0
- Updated MCP Swift SDK: 0.10.2 → 0.11.0 (2025-11-25 spec, HTTP transport, icons/metadata)
- Updated mlx-swift-lm to latest main (strict concurrency for MLXEmbedders)
- Write tools conditionally loaded only when `ZOTERO_API_KEY` is present
- Tool count: 15 → 21 (17 read + 4 write when API key is set)

### Fixed
- N/A

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
