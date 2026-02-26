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

## Tools (23)

### Zotero Library — Read (12)

| Tool | Description |
|------|-------------|
| `zotero_search` | Keyword search (title, creator, tags) |
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

### Zotero Library — Write (4, requires `ZOTERO_API_KEY`)

| Tool | Description |
|------|-------------|
| `zotero_create_collection` | Create a new collection |
| `zotero_add_item_by_doi` | Add paper by DOI (auto-fills from OpenAlex) |
| `zotero_create_item` | Create item with explicit fields |
| `zotero_add_to_collection` | Add existing item to a collection |

### Academic Search (5)

| Tool | Description |
|------|-------------|
| `academic_search` | Search external literature (OpenAlex, 250M+ papers) |
| `academic_get_paper` | Get full paper metadata by DOI |
| `academic_get_citations` | Forward citation tracking |
| `academic_get_references` | Backward reference tracking |
| `academic_search_author` | Search papers by author name |

### Publication Import (2)

| Tool | Description |
|------|-------------|
| `orcid_get_publications` | Fetch public publications from an ORCID ID |
| `import_publications_to_zotero` | Batch import from ORCID, OpenAlex, or DOI list (dry-run supported) |

DOI resolution uses cascading fallback: OpenAlex → doi.org content negotiation → Airiti DOI, covering all 12 global DOI Registration Agencies.

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
| `academic_search` | OpenAlex API | 250M+ papers, free |
| `academic_get_paper` | OpenAlex API | Lookup by DOI |
| `academic_get_citations` | OpenAlex API | Forward citations |
| `academic_get_references` | OpenAlex API | Backward references |
| `academic_search_author` | OpenAlex API | Search by author name |
| `orcid_get_publications` | ORCID API | Public publications |
| `import_publications_to_zotero` | OpenAlex + Zotero Web API | Batch import with dedup |

### Common issues

- **`database is locked`** — Zotero desktop is actively writing to SQLite (e.g., syncing, importing). Wait for sync to complete, or briefly close Zotero.
- **Write tools return auth error** — `ZOTERO_API_KEY` not set or expired. Get a new key at https://www.zotero.org/settings/keys/new.
- **Local reads return empty** — MCP may have reconnected and lost the SQLite path. Run `/mcp` to reconnect.

## Requirements

- macOS 14+
- Zotero 7+ installed locally
- Apple Silicon Mac (M1/M2/M3/M4/M5)

## Acknowledgments

- [54yyyu/zotero-mcp](https://github.com/54yyyu/zotero-mcp) — the original Python implementation that inspired this project
- [VecturaKit](https://github.com/Apurer/vecturakit) — reference for MLXEmbedders + hybrid search in Swift
- [MLXEmbedders](https://github.com/ml-explore/mlx-swift-lm) — Apple's official Swift embedding models
- [OpenAlex](https://openalex.org) — free and open academic metadata catalog

## License

MIT
