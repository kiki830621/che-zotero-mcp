# Changelog

## [1.13.0] - 2026-03-06

### Added
- **Crossref REST API** as DOI resolver fallback — directly queries Crossref database for metadata when doi.org content negotiation fails. Covers all Crossref-registered publishers (IEEE, ACM, Elsevier, Springer, Wiley, etc.). Fixes IEEE conference papers (e.g., IJCNN, ICTAI) returning "Paper not found" from `academic_lookup_doi`.
- New `resolveViaCrossref(doi:)` method in `DOIResolver.swift` with Crossref JSON → `ResolvedDOIMetadata` conversion
- New `mapCrossrefType(_:)` for Crossref-specific types (`proceedings-article`, `monograph`, `edited-book`, `reference-entry`, `peer-review`)
- Automatic JATS XML tag stripping from Crossref abstracts
- Polite pool User-Agent with `mailto:` for higher Crossref rate limits (50 req/s vs 1 req/s)

### Changed
- DOI resolution cascade: doi.org → **Crossref REST API** → OpenAlex → Airiti DOI (was: doi.org → OpenAlex → Airiti)
- Updated User-Agent version in DOI resolvers from 1.3.2 → 1.13.0
- Version bump: 1.12.0 → 1.13.0

## [1.12.0] - 2026-03-06

### Added
- **New tool: `zotero_set_in_my_publications`** — Add or remove items from Zotero's built-in "My Publications" collection via Web API. Sets the `inPublications` flag on items. "My Publications" is a special Zotero feature (not a regular collection) for curating your own authored works.

### Changed
- Version bump: 1.11.0 → 1.12.0
- Tool count: 35 → 36

## [1.11.0] - 2026-03-06

### Added
- **New tool: `zotero_list_groups`** — List all Zotero group libraries you have access to. Returns group IDs and names for use with other tools.
- **Group library support** — Added optional `group_id` parameter to 12 tools: `zotero_search`, `zotero_get_collections`, `zotero_get_tags`, `zotero_get_recent`, `zotero_search_by_doi`, `zotero_create_collection`, `zotero_add_item_by_doi`, `zotero_create_item`, `zotero_add_to_collection`, `zotero_add_attachment`, `zotero_delete_item`, `zotero_delete_collection`. Set `group_id` to operate on a group library instead of the personal library.
- **`LibraryTarget` enum** (`ZoteroWebAPI.swift`) — `.user` or `.group(groupId)` for routing Web API calls to the correct library path (`/users/{userId}/` vs `/groups/{groupId}/`).
- **`ZoteroGroup` struct** and `getGroups()` / `resolveLibraryID(groupID:)` methods (`ZoteroReader.swift`) — Query the local SQLite `groups` table to list synced group libraries and resolve groupID → internal libraryID.
- **`libraryID` filtering** in `ZoteroReader` — `search()`, `getCollections()`, `getTags()`, `getRecent()`, `getAllItems()`, `searchByDOI()` now accept optional `libraryID` parameter. When nil (default), queries all libraries (backward compatible). When set, filters to the specified library.

### Changed
- Version bump: 1.10.0 → 1.11.0
- Tool count: 34 → 35
- All `ZoteroWebAPI` write methods now accept optional `target: LibraryTarget = .user` parameter

## [1.10.0] - 2026-03-06

### Added
- **New tool: `zotero_add_attachment`** — Upload a local file (PDF, EPUB, HTML, PNG, JPG) as attachment to a Zotero item via Web API. Implements the full Zotero Web API v3 file upload flow: (1) create attachment item, (2) get upload authorization, (3) upload file to S3, (4) register upload. Supports automatic content type detection from file extension. Files are uploaded to Zotero cloud storage and synced to Zotero desktop on next sync cycle.
- **MD5 hash helper** (`Data.md5Hash`) — CommonCrypto-based MD5 computation for Zotero file upload authorization.

### Changed
- Version bump: 1.9.0 → 1.10.0
- Tool count: 33 → 34 (write tools: 8 → 9)

## [1.9.0] - 2026-03-05

### Added
- **New tool: `zotero_find_duplicates`** — Detect and merge duplicate items in your Zotero library. Two-step workflow: (1) `action='scan'` scans library/collection for duplicates, grouped by confidence level: HIGH (same DOI), MEDIUM (similar title + author/year, Jaccard >= 0.85), LOW (near-identical title only, Jaccard >= 0.95). Returns groups with recommended item to keep based on item type priority, field completeness, and recency. (2) `action='merge'` merges specific duplicates: keeps the primary item, unions tags/collections from all duplicates, fills missing fields from secondaries, and deletes the inferior copies via Zotero Web API.
- **`DuplicateDetector.swift`** — Duplicate detection engine with three-tier confidence system, word-level Jaccard title similarity, author overlap detection, year matching, and intelligent primary selection (journalArticle > book > conferencePaper > preprint > ..., then completeness score, then recency).

### Changed
- Version bump: 1.8.0 → 1.9.0
- Tool count: 32 → 33 (write tools: 7 → 8)

## [1.8.0] - 2026-03-05

### Added
- **New tool: `zotero_normalize_titles`** — Batch convert Title Case titles to APA-compliant sentence case with proper noun preservation. Most Zotero imports deliver Title Case from publishers; APA 7 and biblatex-apa require sentence case. The tool: (1) detects Title Case vs sentence case titles, (2) converts to sentence case, (3) preserves proper nouns using a built-in list of ~500 terms, (4) supports `dry_run` preview before writing. Writes via Zotero Web API.
- **`ProperNounList.swift`** — Built-in list of ~500 proper nouns organized by category: country/territory names (ISO 3166), nationality/language adjectives, academic eponyms (Bayesian, Freudian, Marxist, Pavlovian, etc.), religions, and historical periods. Used by both `protectProperNouns` (biblatex output) and `zotero_normalize_titles` (title correction).
- **`TitleNormalizer.swift`** — Title Case → sentence case conversion engine. Preserves: ALL CAPS acronyms, camelCase words, known proper nouns, dotted abbreviations, and post-colon capitalization. Skips non-English titles and titles already in sentence case.
- **Sentence case detection heuristic** — `BiblatexAPAFormatter.detectSentenceCase()` computes the ratio of capitalized content words; <40% → sentence case (auto-brace all non-initial capitals), ≥40% → Title Case (brace only known proper nouns and detected patterns).
- **`ZoteroWebAPI.patchItem()`** — Generic PATCH method for updating arbitrary item fields.

### Changed
- Version bump: 1.7.0 → 1.8.0
- Tool count: 31 → 32 (write tools: 6 → 7)
- `BiblatexAPAFormatter.protectProperNouns()` now uses two-strategy approach based on detected casing:
  - Sentence case titles: auto-braces all non-initial capitalized words
  - Title Case titles: braces known proper nouns from `ProperNounList` + existing pattern detection (acronyms, abbreviations, camelCase)
- Biblatex header comment updated to mention proper noun auto-protection and recommend `zotero_normalize_titles`

## [1.7.0] - 2026-03-05

### Added
- **Expose ALL Zotero fields** — `ZoteroItem` now includes `allFields: [String: String]` (all non-empty fields from Zotero's EAV schema) and `creatorDetails: [ZoteroCreator]` (firstName, lastName, creatorType with orderIndex). `zotero_get_metadata` output now shows all fields with creator roles.
- **New tool: `zotero_to_biblatex_apa`** — Convert Zotero items to biblatex-apa format (.bib) compatible with `\usepackage[style=apa,backend=biber]{biblatex}`. Handles 15+ Zotero item types → biblatex entry types, subtitle splitting, date normalization (`2019-02-00` → `2019-02`), pages conversion (`-` → `--`), corporate authors (double braces), creator roles, language→LANGID mapping, and extra field parsing.
- **New tool: `zotero_to_apa`** — Convert Zotero items to APA 7th Edition formatted text. Three output modes: `reference` (formatted entries), `citation` (parenthetical + narrative in-text citations), `reference_list` (alphabetical sorted). Handles 1/2/3-20/21+ author rules, sentence case, italics markers, edition ordinals (2nd/3rd/4th ed.), DOI priority over URL.
- `BiblatexAPAFormatter.swift` — Complete biblatex-apa formatter with field mapping per item type
- `APACitationFormatter.swift` — Complete APA 7 text formatter with all author/body/source formatting rules
- `Server+CitationHandlers.swift` — Tool handlers with unified `resolveItems()` supporting item_key, item_keys, or collection_key

### Changed
- Version bump: 1.6.0 → 1.7.0
- Tool count: 29 → 31 (read tools: 13 → 15)
- `ZoteroReader.buildItem()` now populates `allFields` and `creatorDetails`
- `formatItemDetail()` now outputs all non-empty fields with ordered display and creator roles

## [1.6.0] - 2026-03-05

### Added
- **Graph-theoretic similarity metrics** — `academic_compare_papers` now returns 11 dimensions (was 6):
  - `adamic_adar` — weighted bibliographic coupling: shared references scored by `1/log(cited_by_count)`. Rare shared references are more informative (like IDF in NLP).
  - `resource_allocation` — stronger variant: `1/cited_by_count` weighting
  - `hub_promoted_index` — `|shared|/min(|A|,|B|)`, favors papers with small reference lists
  - `hub_depressed_index` — `|shared|/max(|A|,|B|)`, stricter normalization
  - `shortest_path` — citation graph distance (1 = direct citation, 2 = via shared refs/co-citation, >2 = no short connection)
- **Batch `getCitedByCounts` API** — efficiently fetch citation counts for shared references via OpenAlex `filter=openalex:W1|W2|...` (batched in groups of 50)
- **New tool: `zotero_delete_collection`** — delete a collection container from Zotero (items inside are preserved). Uses Zotero Web API.

### Fixed
- **co_citation API decoding error** — `getCitingWorkDOIs` used `select=doi` which omitted the non-optional `id` field, causing `JSONDecoder` to throw "The data couldn't be read because it is missing" on 26 of 28 paper pairs. Fixed: `select=id,doi`.

### Changed
- Version bump: 1.5.0 → 1.6.0
- Similarity vector: 6 → 11 dimensions
- Tool count: 28 → 29 (write tools: 5 → 6)
- Tool description updated to reflect all 11 dimensions

## [1.5.0] - 2026-03-05

### Added
- **New tools: `zotero_set_config` and `zotero_get_config`** — Persistent key-value config store at `~/.che-zotero-mcp/config.json`
  - Store personal info (`my.orcid`, `my.name`, `my.openalex_author_id`) and any researcher's info (`researchers.<alias>.orcid`, etc.)
  - Supports `set` and `delete` actions
  - Persists across server restarts — no env vars or restart needed
- **Config as reference store** — AI assistants can read stored researcher identifiers via `zotero_get_config` and pass them explicitly to tools like `academic_search_author`

### Changed
- Tool count: 25 → 27
- Version bump: 1.4.0 → 1.5.0

## [1.4.0] - 2026-03-05

### Added
- **New tool: `zotero_get_my_publications`** — List items in your Zotero "My Publications" collection (your own authored works)
  - Uses `publicationsItems` table (i18n-safe internal identifier, not a localized string)
  - **Automatic fallback**: tries local SQLite first; if database is locked (Zotero running), falls back to Zotero Web API
  - Response includes `[Source: local]` or `[Source: web]` tag

### Changed
- Tool count: 24 → 25

## [1.3.3] - 2026-03-05

### Changed
- **`academic_search_author` now supports three identifier types** — ORCID (most precise), OpenAlex Author ID, and name (fallback). Priority: `orcid` > `openalex_author_id` > `name`. Response includes `[filter: ...]` tag indicating which index was used.
- Previously only supported name-based search, which returned papers by different people with similar names (e.g., 50 false positives for "Che Cheng").

### Added
- **`docs/DATA_SOURCE_CREDIBILITY.md`** — Comprehensive documentation of data source credibility hierarchy, source characteristics, known issues (OpenAlex disambiguation pollution), and application in code.

### Fixed
- User-Agent version strings updated to 1.3.3 across AcademicSearchClient

## [1.3.2] - 2026-03-05

### Changed
- **Rename `academic_get_paper` → `academic_lookup_doi`** — "lookup" clearly conveys read-only DOI metadata retrieval, reducing confusion with write tools like `zotero_add_item_by_doi`
- **Credibility-first DOI resolution** — all DOI lookups now prioritize the most authoritative source:
  - DOIResolver cascade reordered: doi.org (publisher-submitted) → OpenAlex (aggregated) → Airiti (Taiwan)
  - `academic_lookup_doi` handler restructured: uses DOIResolver for core metadata, then enriches with OpenAlex supplementary data (citation count, OA status, OpenAlex ID)
  - Previously OpenAlex was queried first, which risked author disambiguation errors overriding authoritative publisher data
- Version bump: 1.3.1 → 1.3.2

## [1.3.1] - 2026-03-05

### Changed
- **Tool description disambiguation** — all 24 tools now include explicit scope tags and cross-references:
  - `[YOUR LIBRARY]` — 12 read tools + 5 write tools that operate on your saved Zotero items
  - `[EXTERNAL DATABASE]` — 7 tools that query OpenAlex/ORCID (global academic literature)
  - `[BRIDGE: EXTERNAL → YOUR LIBRARY]` — import_publications_to_zotero
  - `[YOUR LIBRARY · WRITE]` — 5 write tools with clear write intent
- High-conflict tool pairs now include explicit "Use when..." guidance and "use X instead" cross-references:
  - `zotero_search` ↔ `academic_search` (local vs external search)
  - `zotero_search_by_doi` ↔ `academic_get_paper` (check library vs lookup metadata)
  - `academic_get_paper` ↔ `zotero_add_item_by_doi` (read-only vs save to library)
  - `academic_search_author` ↔ `orcid_get_publications` (name search vs curated list)
- Version bump: 1.3.0 → 1.3.1

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
