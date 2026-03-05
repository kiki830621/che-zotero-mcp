# Tool Description Disambiguation Design

> v1.3.1 — 2026-03-05

## Problem

che-zotero-mcp has 24 tools across three data domains. When a user says something ambiguous like "help me look up this paper", the AI assistant can't determine which tool to use:

| User says | Possible intent A | Possible intent B |
|-----------|-------------------|-------------------|
| "Help me find this paper" | `zotero_search` (check if already saved) | `academic_search` (discover from external DB) |
| "What is DOI 10.xxx?" | `zotero_search_by_doi` (check my library) | `academic_lookup_doi` (look up metadata) |
| "Papers by Dr. Smith" | `zotero_search` (in my collection) | `academic_search_author` (explore globally) |
| "This paper's info" | `zotero_get_metadata` (saved item) | `academic_lookup_doi` (external lookup) |

## Design: Three-Layer Disambiguation

Inspired by [NSQL Reference Resolution Rule](https://github.com/kiki830621/nsql) — zero tolerance for automatic assumptions.

### Layer 1: Scope Tags

Every tool description starts with a bracketed scope tag:

```
[YOUR LIBRARY]              — operates on your saved Zotero items (local SQLite / Web API)
[EXTERNAL DATABASE]         — queries OpenAlex / ORCID (global academic literature)
[BRIDGE: EXTERNAL → YOUR LIBRARY] — transfers data from external sources into Zotero
[YOUR LIBRARY · WRITE]      — modifies your Zotero library (requires API key)
```

The AI sees these tags at tool selection time, providing **instant domain identification** before reading the full description.

### Layer 2: Intent Guide

High-conflict tools include "Use when..." clauses:

```
zotero_search:
  "Use when the user asks about papers in their collection."

academic_search:
  "Use when the user wants to find, explore, or discover research on a topic."
```

This maps **user intent** to the correct tool.

### Layer 3: Cross-References

Each high-conflict tool explicitly points to its counterpart:

```
zotero_search:
  "To discover NEW papers from global academic databases, use academic_search instead."

academic_search:
  "To search within your saved papers, use zotero_search or zotero_semantic_search instead."
```

This creates **bidirectional disambiguation** — no matter which tool the AI considers first, it's guided to the correct one.

## Tool Domain Map

```
┌──────────────────────────────────────────────────────────────┐
│                    [YOUR LIBRARY]                              │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ READ (12 tools)                                         │  │
│  │  zotero_search          zotero_get_metadata             │  │
│  │  zotero_get_collections zotero_get_tags                 │  │
│  │  zotero_get_recent      zotero_semantic_search          │  │
│  │  zotero_build_index     zotero_get_items_in_collection  │  │
│  │  zotero_search_by_doi   zotero_get_attachments          │  │
│  │  zotero_get_notes       zotero_get_annotations          │  │
│  └─────────────────────────────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ WRITE (5 tools, requires ZOTERO_API_KEY)                │  │
│  │  zotero_create_collection  zotero_add_item_by_doi       │  │
│  │  zotero_create_item        zotero_add_to_collection     │  │
│  │  zotero_delete_item                                     │  │
│  └─────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                 [EXTERNAL DATABASE]                            │
│  academic_search        academic_lookup_doi                    │
│  academic_get_citations academic_get_references               │
│  academic_search_author orcid_get_publications                │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│            [BRIDGE: EXTERNAL → YOUR LIBRARY]                  │
│  import_publications_to_zotero                                │
│  (also: zotero_add_item_by_doi has bridge behavior)           │
└──────────────────────────────────────────────────────────────┘
```

## High-Conflict Pairs — Full Cross-Reference Table

| Tool A (YOUR LIBRARY) | Tool B (EXTERNAL) | Disambiguation Signal |
|------------------------|-------------------|----------------------|
| `zotero_search` | `academic_search` | "papers in collection" vs "discover NEW papers" |
| `zotero_semantic_search` | `academic_search` | "can't recall title" vs "explore topic" |
| `zotero_search_by_doi` | `academic_lookup_doi` | "is this saved?" vs "what is this paper?" |
| `zotero_get_metadata` | `academic_lookup_doi` | "item key known" vs "DOI lookup" |
| — | `academic_search_author` vs `orcid_get_publications` | "explore globally" vs "researcher's curated list" |
| `academic_lookup_doi` | `zotero_add_item_by_doi` | "read-only lookup" vs "save to library" |

## Decision Flow

```
User request → Does it mention a specific item_key?
  YES → zotero_get_metadata (YOUR LIBRARY)
  NO  → Does it mention a DOI?
    YES → Does the user want to SAVE it?
      YES → zotero_add_item_by_doi (WRITE)
      NO  → Does the user want to CHECK if it's saved?
        YES → zotero_search_by_doi (YOUR LIBRARY)
        NO  → academic_lookup_doi (EXTERNAL)
    NO  → Is the user looking for papers they ALREADY HAVE?
      YES → zotero_search or zotero_semantic_search (YOUR LIBRARY)
      NO  → Is the user exploring AUTHOR publications?
        YES → Has ORCID ID?
          YES → orcid_get_publications (EXTERNAL)
          NO  → academic_search_author (EXTERNAL)
        NO  → academic_search (EXTERNAL)
```

## Context Signals for AI

The AI should use these context clues to determine intent:

| Signal | Maps to | Example |
|--------|---------|---------|
| "my library", "I have", "saved", "collection" | YOUR LIBRARY | "Do I have papers about X?" |
| "find", "discover", "new", "explore", "search for" | EXTERNAL | "Find recent papers about X" |
| "check", "already", "duplicate", "exists" | YOUR LIBRARY (dedup check) | "Is this DOI already saved?" |
| "add", "save", "import", "download" | WRITE / BRIDGE | "Save this paper to my library" |
| "info about", "what is", "tell me about" | EXTERNAL (if no item_key) | "What is DOI 10.xxx?" |
| "notes", "highlights", "annotations" | YOUR LIBRARY (always) | "Show me my notes on this paper" |
| "citations", "references", "cited by" | EXTERNAL (always) | "What papers cite this?" |

## Future Considerations

- If Zotero adds a full-text search API, a new disambiguation layer would be needed between local full-text and external search
- Consider adding a meta-tool `smart_search` that auto-routes based on intent detection (but this adds complexity)
