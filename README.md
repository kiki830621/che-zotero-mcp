# che-zotero-mcp

A **macOS-native** MCP server for Zotero, built in Swift. Connect your research library with AI assistants — keyword search, semantic search, academic literature discovery, citation tracking — all running locally on Apple Silicon.

Inspired by [54yyyu/zotero-mcp](https://github.com/54yyyu/zotero-mcp) (Python), reimagined as a native macOS application.

## Why a Native Rewrite?

| | [zotero-mcp](https://github.com/54yyyu/zotero-mcp) (Python) | **che-zotero-mcp** (Swift) |
|---|---|---|
| **Language** | Python | Swift |
| **Embedding** | sentence-transformers (PyTorch) | MLXEmbedders (Apple MLX framework) |
| **Default model** | all-MiniLM-L6-v2 (English only, 384-dim) | BAAI/bge-m3 (multilingual, 1024-dim) |
| **Vector DB** | ChromaDB (separate process) | In-memory + Accelerate.framework + SQLite persistence |
| **Zotero access** | pyzotero HTTP client + SQLite | Direct SQLite (read-only) |
| **Dependencies** | ~12 packages (chromadb, torch, openai, etc.) | 2 Swift packages (MCP SDK, MLX) |
| **Runtime** | Python + pip/uv | Single compiled binary |
| **GPU acceleration** | CUDA / CPU fallback | Apple Silicon GPU (Metal) |
| **External services** | Optional (OpenAI, Gemini for embeddings) | OpenAlex for academic search (free, no API key) |
| **Platforms** | Cross-platform | macOS only (Apple Silicon) |

### Key Differences

- **Zero Python dependency** — no pip, no venv, no PyTorch. One binary, runs immediately.
- **Apple Silicon native** — MLX runs embeddings directly on the GPU/Neural Engine via Metal, not through PyTorch.
- **No vector database** — at typical library sizes (<100K papers), brute-force cosine similarity via `Accelerate.framework` (cblas/vDSP) is fast enough. No ChromaDB overhead.
- **Academic search** — integrated OpenAlex API (250M+ papers) for external literature discovery and citation tracking.

## Features

- **Keyword search** — search by title, creator, tags via Zotero's local SQLite
- **Semantic search** — find papers by meaning using MLX embeddings (local, no API key)
- **Academic search** — search external literature, get paper metadata, track citations (OpenAlex)
- **ORCID import** — fetch publications from ORCID, batch import to Zotero with dedup
- **Universal DOI resolution** — cascading resolver covering all 12 DOI Registration Agencies
- **Write operations** — create collections, add items by DOI, manage library (Zotero Web API)
- **Notes & annotations** — read item notes and PDF highlights/comments
- **Metadata retrieval** — get full bibliographic info, DOI lookup, attachment paths
- **Collections & tags** — browse library structure
- **Persistent embeddings** — semantic search index survives server restarts

## Architecture

```
┌─────────────────────────────────────┐
│  Zotero SQLite (read-only)          │
│  ~/Zotero/zotero.sqlite            │
└──────────────┬──────────────────────┘
               │
       ┌───────┴────────┐
       │                │
  Keyword Search   Semantic Search
  (SQL queries)    (MLXEmbedders on Apple Silicon GPU)
       │                │
       │           Accelerate.framework
       │           (vDSP cosine similarity)
       │                │
       │           SQLite Persistence
       │           (~/.che-zotero-mcp/embeddings.sqlite)
       │                │
       └───────┬────────┘
               │
         MCP Server (stdio)
               │
       ┌───────┴────────┐
       │                │
  Zotero Tools     Academic Tools
  (10 tools)       (5 tools, OpenAlex API)
```

## Dependencies

- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) — MCP protocol
- [MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm) — local embedding on Apple Silicon
- [OpenAlex API](https://openalex.org) — academic literature search (free, no API key)

## Installation

### Claude Code CLI

```bash
# Read-only mode (no API key needed)
claude mcp add --scope user --transport stdio che-zotero-mcp -- ~/bin/CheZoteroMCP

# Read + Write mode (with Zotero API key for creating items/collections)
claude mcp add --scope user --transport stdio -e ZOTERO_API_KEY=your_key che-zotero-mcp -- ~/bin/CheZoteroMCP
```

Get your Zotero API key at: https://www.zotero.org/settings/keys/new (enable library read/write access)

## Tools (33)

### Zotero Library — Read (13)

| Tool | Description |
|------|-------------|
| `zotero_search` | Keyword search (title, creator, tags) |
| `zotero_get_my_publications` | List items in "My Publications" (local → Web API fallback) |
| `zotero_get_metadata` | Get detailed metadata for an item |
| `zotero_get_collections` | List all collections |
| `zotero_get_tags` | List all tags |
| `zotero_get_recent` | Get recently added items |
| `zotero_semantic_search` | Semantic search via MLX embeddings |
| `zotero_build_index` | Build/rebuild the embedding index (persisted to disk) |
| `zotero_get_items_in_collection` | List items in a specific collection |
| `zotero_search_by_doi` | Find item by DOI |
| `zotero_get_attachments` | Get PDF attachment paths |
| `zotero_get_notes` | Get notes attached to an item (plain text) |
| `zotero_get_annotations` | Get PDF annotations (highlights, comments) |

### Zotero Library — Write (8, requires `ZOTERO_API_KEY`)

| Tool | Description |
|------|-------------|
| `zotero_create_collection` | Create a new collection (idempotent) |
| `zotero_add_item_by_doi` | Add paper by DOI (auto-fills from OpenAlex, idempotent) |
| `zotero_create_item` | Create item with explicit fields (idempotent if DOI provided) |
| `zotero_add_to_collection` | Add existing item to a collection |
| `zotero_delete_item` | Delete an item by key |
| `zotero_delete_collection` | Delete a collection container (items inside preserved) |
| `zotero_normalize_titles` | Batch Title Case → sentence case with proper noun preservation (dry_run supported) |
| `zotero_find_duplicates` | Detect and merge duplicate items (scan → confirm → merge workflow) |

### Academic Search & Analysis (6)

| Tool | Description |
|------|-------------|
| `academic_search` | Search external literature (OpenAlex, 250M+ papers) |
| `academic_lookup_doi` | Get full paper metadata by DOI |
| `academic_get_citations` | Forward citation tracking |
| `academic_get_references` | Backward reference tracking |
| `academic_search_author` | Search papers by author (ORCID > Author ID > name) |
| `academic_compare_papers` | 11-dimension similarity vector (semantic, bib coupling, Adamic-Adar, RA, HPI, HDI, co-citation, author, venue, tags, shortest path) |

### Publication Import (2)

| Tool | Description |
|------|-------------|
| `orcid_get_publications` | Fetch public publications from an ORCID ID |
| `import_publications_to_zotero` | Batch import from ORCID, OpenAlex, or DOI list (dry-run supported) |

DOI resolution uses credibility-first cascading fallback: doi.org (publisher-submitted) → OpenAlex (aggregated) → Airiti DOI (regional), covering all 12 global DOI Registration Agencies.

### Citation Formatting (2)

| Tool | Description |
|------|-------------|
| `zotero_to_biblatex_apa` | Convert items to biblatex-apa .bib format (compatible with `biblatex-apa` package) |
| `zotero_to_apa` | Convert items to APA 7th Edition text (reference / citation / reference_list) |

All three input modes supported: single `item_key`, multiple `item_keys`, or entire `collection_key`.

### Config (2)

| Tool | Description |
|------|-------------|
| `zotero_set_config` | Store persistent key-value config (e.g. `my.orcid`, `researchers.advisor.name`) |
| `zotero_get_config` | Read config values (single key or all) |

Config is stored at `~/.che-zotero-mcp/config.json` and persists across server restarts. AI assistants can read stored values via `zotero_get_config` and pass them explicitly to other tools.

### Tool Disambiguation Guide

All tool descriptions include scope tags (`[YOUR LIBRARY]`, `[EXTERNAL DATABASE]`, `[BRIDGE]`, `[WRITE]`) and cross-references to prevent AI from picking the wrong tool.

**Common ambiguous requests and correct tool selection:**

| User says | Intent | Correct Tool | NOT this |
|-----------|--------|-------------|----------|
| "Do I have this paper?" | Check existing library | `zotero_search` / `zotero_search_by_doi` | ~~academic_search~~ |
| "Find papers about X" | Discover new research | `academic_search` | ~~zotero_search~~ |
| "What is DOI 10.xxx?" | Look up paper info | `academic_lookup_doi` | ~~zotero_search_by_doi~~ |
| "Is this DOI in my library?" | Check if saved | `zotero_search_by_doi` | ~~academic_lookup_doi~~ |
| "Save this paper" | Add to Zotero | `zotero_add_item_by_doi` | ~~academic_lookup_doi~~ |
| "Papers by Dr. Smith" | Author exploration | `academic_search_author` | ~~zotero_search~~ |
| "What did I read about X?" | Recall from library | `zotero_semantic_search` | ~~academic_search~~ |

## Data Sources

Each tool connects to one of three data sources. Understanding this helps troubleshoot issues like `database is locked`.

| Data Source | Connection | Requires | Failure Mode |
|---|---|---|---|
| **Local SQLite** | `~/Zotero/zotero.sqlite` (read-only) | Zotero installed | `database is locked` when Zotero is syncing/writing |
| **Zotero Web API** | `api.zotero.org` | `ZOTERO_API_KEY` + internet | Network errors, auth failures |
| **OpenAlex API** | `api.openalex.org` | Internet (no API key) | Network errors, rate limits |

### Tools by data source

| Tool | Source | Notes |
|------|--------|-------|
| `zotero_get_my_publications` | Local SQLite → Zotero Web API | Auto-fallback when DB locked |
| `zotero_search` | Local SQLite | |
| `zotero_get_metadata` | Local SQLite | |
| `zotero_get_collections` | Local SQLite | |
| `zotero_get_tags` | Local SQLite | |
| `zotero_get_recent` | Local SQLite | |
| `zotero_get_items_in_collection` | Local SQLite | |
| `zotero_search_by_doi` | Local SQLite | |
| `zotero_get_attachments` | Local SQLite | Returns local file paths |
| `zotero_get_notes` | Local SQLite | |
| `zotero_get_annotations` | Local SQLite | |
| `zotero_semantic_search` | Local SQLite + in-memory index | Run `zotero_build_index` first |
| `zotero_build_index` | Local SQLite → local embeddings | Uses MLX on Apple Silicon GPU |
| `zotero_create_collection` | Zotero Web API | Requires `ZOTERO_API_KEY` |
| `zotero_add_item_by_doi` | Zotero Web API + OpenAlex | Metadata from OpenAlex, writes via API |
| `zotero_create_item` | Zotero Web API | Requires `ZOTERO_API_KEY` |
| `zotero_add_to_collection` | Zotero Web API | Requires `ZOTERO_API_KEY` |
| `zotero_delete_item` | Zotero Web API | Requires `ZOTERO_API_KEY` |
| `zotero_delete_collection` | Zotero Web API | Requires `ZOTERO_API_KEY` |
| `academic_search` | OpenAlex API | 250M+ papers, free |
| `academic_lookup_doi` | OpenAlex API | Lookup by DOI |
| `academic_get_citations` | OpenAlex API | Forward citations |
| `academic_get_references` | OpenAlex API | Backward references |
| `academic_search_author` | OpenAlex API | Search by author name |
| `orcid_get_publications` | ORCID API | Public publications |
| `import_publications_to_zotero` | OpenAlex + Zotero Web API | Batch import with dedup |
| `academic_compare_papers` | OpenAlex API + Local SQLite | Graph metrics + embeddings |
| `zotero_to_biblatex_apa` | Local SQLite | Converts items to biblatex-apa .bib format |
| `zotero_to_apa` | Local SQLite | Converts items to APA 7 formatted text |
| `zotero_normalize_titles` | Local SQLite + Zotero Web API | Reads local, writes via API |
| `zotero_find_duplicates` | Local SQLite + Zotero Web API | Scan reads local, merge writes via API |
| `zotero_set_config` | Local file | `~/.che-zotero-mcp/config.json` |
| `zotero_get_config` | Local file | `~/.che-zotero-mcp/config.json` |

### Common issues

- **`database is locked`** — Zotero desktop is actively writing to SQLite (e.g., syncing, importing). Wait for sync to complete, or briefly close Zotero.
- **Write tools return auth error** — `ZOTERO_API_KEY` not set or expired. Get a new key at https://www.zotero.org/settings/keys/new.
- **Local reads return empty** — MCP may have reconnected and lost the SQLite path. Run `/mcp` to reconnect.

## Requirements

- macOS 14+
- Zotero 7+ installed locally
- Apple Silicon Mac (M1/M2/M3/M4/M5)

## Version History

| Version | Changes |
|---------|---------|
| v1.9.0 | Duplicate detection and merge: `zotero_find_duplicates` (scan → confirm → merge), 3-tier confidence (DOI/title+author/title-only), intelligent primary selection |
| v1.8.0 | Title normalization: `zotero_normalize_titles` (batch Title Case → sentence case), proper noun list (~500 terms), sentence case detection heuristic, enhanced `protectProperNouns` |
| v1.7.0 | Citation formatting: `zotero_to_biblatex_apa` (biblatex-apa .bib), `zotero_to_apa` (APA 7 text). All Zotero fields exposed. |
| v1.6.0 | 11-dimension similarity vector with graph-theoretic metrics, `zotero_delete_collection`, co-citation bug fix |
| v1.5.0 | Config system (`zotero_set_config`/`zotero_get_config`) |
| v1.4.0 | `zotero_get_my_publications` with local→web fallback |
| v1.3.3 | `academic_search_author` supports ORCID/Author ID/name (3 identifier types) |
| v1.3.2 | Credibility-first DOI resolution, rename `academic_get_paper` → `academic_lookup_doi` |
| v1.3.0 | Write idempotency, `zotero_delete_item` |
| v1.2.0 | ORCID integration, universal DOI resolver, batch import |
| v1.1.0 | Zotero Web API write tools, notes & annotations |
| v1.0.0 | Academic search (OpenAlex), embedding persistence, enhanced Zotero tools |
| v0.1.0 | Initial release — keyword search, semantic search, basic Zotero tools |

## Acknowledgments

- [54yyyu/zotero-mcp](https://github.com/54yyyu/zotero-mcp) — the original Python implementation that inspired this project
- [VecturaKit](https://github.com/Apurer/vecturakit) — reference for MLXEmbedders + hybrid search in Swift
- [MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm) — Apple's official Swift embedding models
- [OpenAlex](https://openalex.org) — free and open academic metadata catalog

## License

MIT
