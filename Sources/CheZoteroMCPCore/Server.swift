// Sources/CheZoteroMCPCore/Server.swift
import Foundation
import MCP

public class CheZoteroMCPServer {
    let server: Server
    let transport: StdioTransport
    let tools: [Tool]
    let reader: ZoteroReader
    let embeddings: EmbeddingManager
    let academic: AcademicSearchClient
    let orcid: OrcidClient
    let doiResolver: DOIResolver
    let webAPI: ZoteroWebAPI?

    public init() async throws {
        reader = try ZoteroReader()
        embeddings = EmbeddingManager()
        academic = AcademicSearchClient()
        orcid = OrcidClient()
        doiResolver = DOIResolver(academic: academic)

        // Try to initialize Web API (requires ZOTERO_API_KEY env var)
        webAPI = try? await ZoteroWebAPI.createFromEnvironment()

        tools = Self.defineTools(hasWebAPI: webAPI != nil)

        server = Server(
            name: "che-zotero-mcp",
            version: "1.3.0",
            capabilities: .init(tools: .init())
        )

        transport = StdioTransport()
        await registerHandlers()
    }

    public func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    private static func defineTools(hasWebAPI: Bool = false) -> [Tool] {
        var allTools: [Tool] = [
            // --- Zotero Library Tools (7) ---
            Tool(
                name: "zotero_search",
                description: "Search Zotero library by keyword (title, creator, abstract, tags)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10)")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "zotero_get_metadata",
                description: "Get detailed metadata for a Zotero item by its key",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("item_key")])
                ])
            ),
            Tool(
                name: "zotero_get_collections",
                description: "List all collections in the Zotero library",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "zotero_get_tags",
                description: "List all tags in the Zotero library with usage counts",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "zotero_get_recent",
                description: "Get recently added items",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Number of recent items (default: 10)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "zotero_semantic_search",
                description: "Semantic search using MLX embeddings (BAAI/bge-m3) — find papers by meaning, not just keywords. Requires index to be built first.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Natural language search query")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10)")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "zotero_build_index",
                description: "Build or rebuild the semantic search index from Zotero library. Downloads the embedding model on first run (~1.5GB). Index is persisted to disk.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ),

            // --- Enhanced Zotero Tools (3) ---
            Tool(
                name: "zotero_get_items_in_collection",
                description: "List all items in a specific Zotero collection by its key",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "collection_key": .object([
                            "type": .string("string"),
                            "description": .string("Collection key (use zotero_get_collections to find keys)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 50)")
                        ])
                    ]),
                    "required": .array([.string("collection_key")])
                ])
            ),
            Tool(
                name: "zotero_search_by_doi",
                description: "Search Zotero library for an item by its DOI",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doi": .object([
                            "type": .string("string"),
                            "description": .string("DOI to search for (with or without https://doi.org/ prefix)")
                        ])
                    ]),
                    "required": .array([.string("doi")])
                ])
            ),
            Tool(
                name: "zotero_get_attachments",
                description: "Get PDF attachment file paths for a Zotero item",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("item_key")])
                ])
            ),

            // --- Academic Search Tools (5) ---
            Tool(
                name: "academic_search",
                description: "Search external academic literature via OpenAlex (250M+ papers). Returns titles, authors, year, citation count, DOI, and open access status.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query (keywords, topic, or paper title)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10, max: 50)")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "academic_get_paper",
                description: "Get full metadata for an academic paper by DOI, including abstract, authors, institutions, citation count, and open access info",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doi": .object([
                            "type": .string("string"),
                            "description": .string("DOI of the paper (with or without https://doi.org/ prefix)")
                        ])
                    ]),
                    "required": .array([.string("doi")])
                ])
            ),
            Tool(
                name: "academic_get_citations",
                description: "Get papers that cite a given work (forward citation tracking). Use OpenAlex ID from academic_search results.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "openalex_id": .object([
                            "type": .string("string"),
                            "description": .string("OpenAlex work ID (e.g. 'W1234567890' or full URL)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10, max: 50)")
                        ])
                    ]),
                    "required": .array([.string("openalex_id")])
                ])
            ),
            Tool(
                name: "academic_get_references",
                description: "Get papers referenced by a given work (backward reference tracking). Use OpenAlex ID from academic_search results.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "openalex_id": .object([
                            "type": .string("string"),
                            "description": .string("OpenAlex work ID (e.g. 'W1234567890' or full URL)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10, max: 50)")
                        ])
                    ]),
                    "required": .array([.string("openalex_id")])
                ])
            ),
            Tool(
                name: "academic_search_author",
                description: "Search academic papers by a specific author's name",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Author name to search for")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10, max: 50)")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),

            // --- ORCID / Publication Import (2) ---
            Tool(
                name: "orcid_get_publications",
                description: "List publications from an ORCID profile (public data, no auth required). Returns the researcher's self-curated publication list with titles, years, DOIs, and journal names.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "orcid_id": .object([
                            "type": .string("string"),
                            "description": .string("ORCID ID (e.g. '0000-0003-3376-7833' or full URL)")
                        ])
                    ]),
                    "required": .array([.string("orcid_id")])
                ])
            ),
            Tool(
                name: "import_publications_to_zotero",
                description: "Import publications to Zotero from multiple sources. Sources: 'orcid' (authoritative, user-curated — recommended for 'my publications'), 'openalex_orcid' (broader discovery via OpenAlex, may include false positives from name disambiguation), 'dois' (manual DOI list). Uses OpenAlex to enrich metadata. Supports dry_run preview and skip_existing to avoid duplicates.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object([
                            "type": .string("string"),
                            "enum": .array([.string("orcid"), .string("openalex_orcid"), .string("dois")]),
                            "description": .string("Import source: 'orcid' (user-curated, most accurate), 'openalex_orcid' (broader but may have false positives), 'dois' (manual DOI list)")
                        ]),
                        "orcid_id": .object([
                            "type": .string("string"),
                            "description": .string("ORCID ID — required for 'orcid' and 'openalex_orcid' sources")
                        ]),
                        "dois": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("List of DOIs — required for 'dois' source")
                        ]),
                        "collection_key": .object([
                            "type": .string("string"),
                            "description": .string("Collection key to add imported items to (optional)")
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Tags to apply to imported items (optional)")
                        ]),
                        "dry_run": .object([
                            "type": .string("boolean"),
                            "description": .string("Preview only, don't actually create items (default: true)")
                        ]),
                        "skip_existing": .object([
                            "type": .string("boolean"),
                            "description": .string("Skip items already in Zotero library by DOI (default: true)")
                        ])
                    ]),
                    "required": .array([.string("source")])
                ])
            ),

            // --- Notes & Annotations (2) ---
            Tool(
                name: "zotero_get_notes",
                description: "Get all notes attached to a Zotero item (plain text, HTML stripped)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("item_key")])
                ])
            ),
            Tool(
                name: "zotero_get_annotations",
                description: "Get PDF annotations (highlights, notes, underlines) for a Zotero item",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("item_key")])
                ])
            ),
        ]

        // --- Write Tools (require ZOTERO_API_KEY) ---
        if hasWebAPI {
            allTools.append(contentsOf: [
                Tool(
                    name: "zotero_create_collection",
                    description: "Create a new collection in Zotero (via Web API)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Collection name")
                            ]),
                            "parent_key": .object([
                                "type": .string("string"),
                                "description": .string("Parent collection key (optional, omit for top-level)")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "zotero_add_item_by_doi",
                    description: "Add a paper to Zotero by DOI — auto-fills metadata from OpenAlex (title, authors, abstract, journal, date). Optionally add to collections and apply tags.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "doi": .object([
                                "type": .string("string"),
                                "description": .string("DOI of the paper (with or without https://doi.org/ prefix)")
                            ]),
                            "collection_keys": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Collection keys to add the item to (optional)")
                            ]),
                            "tags": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Tags to apply (optional)")
                            ])
                        ]),
                        "required": .array([.string("doi")])
                    ])
                ),
                Tool(
                    name: "zotero_create_item",
                    description: "Create a new item in Zotero with explicit fields (via Web API). For adding by DOI with auto-fill, use zotero_add_item_by_doi instead.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_type": .object([
                                "type": .string("string"),
                                "description": .string("Item type (e.g. journalArticle, book, conferencePaper, thesis, report)")
                            ]),
                            "title": .object([
                                "type": .string("string"),
                                "description": .string("Item title")
                            ]),
                            "creators": .object([
                                "type": .string("array"),
                                "items": .object([
                                    "type": .string("object"),
                                    "properties": .object([
                                        "firstName": .object(["type": .string("string")]),
                                        "lastName": .object(["type": .string("string")])
                                    ])
                                ]),
                                "description": .string("Authors as [{firstName, lastName}] (optional)")
                            ]),
                            "doi": .object([
                                "type": .string("string"),
                                "description": .string("DOI (optional)")
                            ]),
                            "publication_title": .object([
                                "type": .string("string"),
                                "description": .string("Journal/conference name (optional)")
                            ]),
                            "date": .object([
                                "type": .string("string"),
                                "description": .string("Publication date (optional)")
                            ]),
                            "abstract": .object([
                                "type": .string("string"),
                                "description": .string("Abstract (optional)")
                            ]),
                            "collection_keys": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Collection keys (optional)")
                            ]),
                            "tags": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Tags (optional)")
                            ])
                        ]),
                        "required": .array([.string("item_type"), .string("title")])
                    ])
                ),
                Tool(
                    name: "zotero_add_to_collection",
                    description: "Add an existing Zotero item to a collection (via Web API)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_key": .object([
                                "type": .string("string"),
                                "description": .string("Zotero item key")
                            ]),
                            "collection_key": .object([
                                "type": .string("string"),
                                "description": .string("Collection key to add the item to")
                            ])
                        ]),
                        "required": .array([.string("item_key"), .string("collection_key")])
                    ])
                ),
                Tool(
                    name: "zotero_delete_item",
                    description: "Delete an item from Zotero by its key (via Web API). This permanently removes the item and its child notes/attachments.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_key": .object([
                                "type": .string("string"),
                                "description": .string("Zotero item key to delete")
                            ])
                        ]),
                        "required": .array([.string("item_key")])
                    ])
                ),
            ])
        }

        return allTools
    }

    // MARK: - Handler Registration

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await self.handleToolCall(params)
        }
    }

    private func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            switch params.name {
            // Zotero Library Tools
            case "zotero_search":
                return try handleSearch(params)
            case "zotero_get_metadata":
                return try handleGetMetadata(params)
            case "zotero_get_collections":
                return try handleGetCollections()
            case "zotero_get_tags":
                return try handleGetTags()
            case "zotero_get_recent":
                return try handleGetRecent(params)
            case "zotero_semantic_search":
                return try await handleSemanticSearch(params)
            case "zotero_build_index":
                return try await handleBuildIndex()

            // Enhanced Zotero Tools
            case "zotero_get_items_in_collection":
                return try handleGetItemsInCollection(params)
            case "zotero_search_by_doi":
                return try handleSearchByDOI(params)
            case "zotero_get_attachments":
                return try handleGetAttachments(params)

            // Academic Search Tools
            case "academic_search":
                return try await handleAcademicSearch(params)
            case "academic_get_paper":
                return try await handleAcademicGetPaper(params)
            case "academic_get_citations":
                return try await handleAcademicGetCitations(params)
            case "academic_get_references":
                return try await handleAcademicGetReferences(params)
            case "academic_search_author":
                return try await handleAcademicSearchAuthor(params)

            // ORCID / Publication Import
            case "orcid_get_publications":
                return try await handleOrcidGetPublications(params)
            case "import_publications_to_zotero":
                return try await handleImportPublications(params)

            // Notes & Annotations
            case "zotero_get_notes":
                return try handleGetNotes(params)
            case "zotero_get_annotations":
                return try handleGetAnnotations(params)

            // Write Tools (Web API)
            case "zotero_create_collection":
                return try await handleCreateCollection(params)
            case "zotero_add_item_by_doi":
                return try await handleAddItemByDOI(params)
            case "zotero_create_item":
                return try await handleCreateItem(params)
            case "zotero_add_to_collection":
                return try await handleAddToCollection(params)
            case "zotero_delete_item":
                return try await handleDeleteItem(params)

            default:
                return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

}

