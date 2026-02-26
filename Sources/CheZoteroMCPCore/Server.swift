// Sources/CheZoteroMCPCore/Server.swift
import Foundation
import MCP

public class CheZoteroMCPServer {
    private let server: Server
    private let transport: StdioTransport
    private let tools: [Tool]
    private let reader: ZoteroReader
    private let embeddings: EmbeddingManager
    private let academic: AcademicSearchClient
    private let orcid: OrcidClient
    private let doiResolver: DOIResolver
    private let webAPI: ZoteroWebAPI?

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
            version: "1.2.1",
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

            default:
                return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    // MARK: - Zotero Library Handlers

    private func handleSearch(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let query = params.arguments?["query"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let items = try reader.search(query: query, limit: limit)
        let text = formatItems(items, header: "Search results for '\(query)'")
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    private func handleGetMetadata(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let itemKey = params.arguments?["item_key"]?.stringValue ?? ""

        guard let item = try reader.getItem(key: itemKey) else {
            return CallTool.Result(content: [.text("Item not found: \(itemKey)")], isError: true)
        }

        let text = formatItemDetail(item)
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    private func handleGetCollections() throws -> CallTool.Result {
        let collections = try reader.getCollections()

        if collections.isEmpty {
            return CallTool.Result(content: [.text("No collections found.")], isError: false)
        }

        var lines = ["Collections (\(collections.count)):"]
        for c in collections {
            let parent = c.parentKey != nil ? " (sub-collection)" : ""
            lines.append("- \(c.name) [\(c.itemCount) items]\(parent) (key: \(c.key))")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    private func handleGetTags() throws -> CallTool.Result {
        let tags = try reader.getTags()

        if tags.isEmpty {
            return CallTool.Result(content: [.text("No tags found.")], isError: false)
        }

        var lines = ["Tags (\(tags.count)):"]
        for t in tags {
            lines.append("- \(t.name) (\(t.count) items)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    private func handleGetRecent(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let limit = intFromValue(params.arguments?["limit"]) ?? 10
        let items = try reader.getRecent(limit: limit)
        let text = formatItems(items, header: "Recent \(items.count) items")
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    private func handleSemanticSearch(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let query = params.arguments?["query"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        guard embeddings.indexCount > 0 else {
            return CallTool.Result(
                content: [.text("Semantic search index is empty. Run zotero_build_index first.")],
                isError: true
            )
        }

        let results = try await embeddings.search(query: query, limit: limit)

        var lines = ["Semantic search results for '\(query)' (\(results.count) matches):"]
        for (i, result) in results.enumerated() {
            let similarity = String(format: "%.3f", result.similarity)
            if let item = try? reader.getItem(key: result.itemKey) {
                let creators = item.creators.isEmpty ? "" : " — \(item.creators.joined(separator: ", "))"
                lines.append("\(i + 1). [\(similarity)] \(item.title)\(creators) (\(item.date ?? "n.d.")) [key: \(item.key)]")
            } else {
                lines.append("\(i + 1). [\(similarity)] key: \(result.itemKey)")
            }
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    private func handleBuildIndex() async throws -> CallTool.Result {
        try await embeddings.loadModel()

        let items = try reader.getAllItems()
        var processed = 0

        for item in items {
            let embedding = try await embeddings.embed(text: item.searchableText)
            embeddings.addToIndex(itemKey: item.key, embedding: embedding)
            processed += 1
        }

        // Persist to disk
        embeddings.saveToDisk()

        return CallTool.Result(
            content: [.text("Index built and saved: \(processed) items embedded using \(EmbeddingManager.defaultModelID)")],
            isError: false
        )
    }

    // MARK: - Enhanced Zotero Handlers

    private func handleGetItemsInCollection(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let collectionKey = params.arguments?["collection_key"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 50

        let items = try reader.getItemsInCollection(collectionKey: collectionKey, limit: limit)
        let text = formatItems(items, header: "Items in collection '\(collectionKey)'")
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    private func handleSearchByDOI(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let doi = params.arguments?["doi"]?.stringValue ?? ""

        guard let item = try reader.searchByDOI(doi: doi) else {
            return CallTool.Result(content: [.text("No item found with DOI: \(doi)")], isError: false)
        }

        let text = formatItemDetail(item)
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    private func handleGetAttachments(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let itemKey = params.arguments?["item_key"]?.stringValue ?? ""

        let attachments = try reader.getAttachments(itemKey: itemKey)

        if attachments.isEmpty {
            return CallTool.Result(content: [.text("No attachments found for item: \(itemKey)")], isError: false)
        }

        var lines = ["Attachments for \(itemKey) (\(attachments.count)):"]
        for a in attachments {
            let exists = a.path != nil && FileManager.default.fileExists(atPath: a.path!) ? "exists" : "missing"
            lines.append("- \(a.filename) [\(a.contentType)] (\(exists))")
            if let path = a.path {
                lines.append("  Path: \(path)")
            }
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Academic Search Handlers

    private func handleAcademicSearch(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let query = params.arguments?["query"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let works = try await academic.search(query: query, limit: limit)

        if works.isEmpty {
            return CallTool.Result(content: [.text("No results for '\(query)'")], isError: false)
        }

        var lines = ["Academic search: '\(query)' (\(works.count) results):"]
        for (i, work) in works.enumerated() {
            lines.append(work.summary(index: i + 1))
            lines.append("  OpenAlex: \(work.openAlexID)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    private func handleAcademicGetPaper(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let doi = params.arguments?["doi"]?.stringValue ?? ""

        guard let work = try await academic.getWork(doi: doi) else {
            return CallTool.Result(content: [.text("Paper not found for DOI: \(doi)")], isError: false)
        }

        return CallTool.Result(content: [.text(work.detail())], isError: false)
    }

    private func handleAcademicGetCitations(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let openAlexID = params.arguments?["openalex_id"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let works = try await academic.getCitations(openAlexID: openAlexID, limit: limit)

        if works.isEmpty {
            return CallTool.Result(content: [.text("No citations found for \(openAlexID)")], isError: false)
        }

        var lines = ["Papers citing \(openAlexID) (\(works.count) results):"]
        for (i, work) in works.enumerated() {
            lines.append(work.summary(index: i + 1))
            lines.append("  OpenAlex: \(work.openAlexID)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    private func handleAcademicGetReferences(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let openAlexID = params.arguments?["openalex_id"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let works = try await academic.getReferences(openAlexID: openAlexID, limit: limit)

        if works.isEmpty {
            return CallTool.Result(content: [.text("No references found for \(openAlexID)")], isError: false)
        }

        var lines = ["References of \(openAlexID) (\(works.count) results):"]
        for (i, work) in works.enumerated() {
            lines.append(work.summary(index: i + 1))
            lines.append("  OpenAlex: \(work.openAlexID)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    private func handleAcademicSearchAuthor(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let name = params.arguments?["name"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let works = try await academic.searchByAuthor(name: name, limit: limit)

        if works.isEmpty {
            return CallTool.Result(content: [.text("No papers found for author '\(name)'")], isError: false)
        }

        var lines = ["Papers by '\(name)' (\(works.count) results):"]
        for (i, work) in works.enumerated() {
            lines.append(work.summary(index: i + 1))
            lines.append("  OpenAlex: \(work.openAlexID)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - ORCID / Publication Import Handlers

    private func handleOrcidGetPublications(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let orcidId = params.arguments?["orcid_id"]?.stringValue ?? ""

        let works = try await orcid.getPublications(orcidId: orcidId)

        if works.isEmpty {
            return CallTool.Result(
                content: [.text("No public publications found for ORCID: \(orcidId)\nNote: Only works with 'public' visibility on ORCID are returned.")],
                isError: false
            )
        }

        var lines = ["ORCID publications for \(orcidId) (\(works.count)):"]
        for (i, work) in works.enumerated() {
            let year = work.publicationYear != nil ? "(\(work.publicationYear!))" : "(n.d.)"
            let journal = work.journalTitle != nil ? " — \(work.journalTitle!)" : ""
            let doi = work.doi != nil ? " doi:\(work.doi!)" : " (no DOI)"
            let type = work.type ?? "unknown"
            lines.append("\(i + 1). \(work.title) \(year)\(journal) [\(type)]\(doi)")
        }
        lines.append("\nNote: Only works with 'public' visibility on ORCID are listed. Use import_publications_to_zotero with source='orcid' to import these.")
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    private func handleImportPublications(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let source = params.arguments?["source"]?.stringValue ?? ""
        let orcidId = params.arguments?["orcid_id"]?.stringValue
        let doisParam = extractStringArray(params.arguments?["dois"])
        let collectionKey = params.arguments?["collection_key"]?.stringValue
        let tags = extractStringArray(params.arguments?["tags"])
        let dryRun = params.arguments?["dry_run"]?.boolValue ?? true
        let skipExisting = params.arguments?["skip_existing"]?.boolValue ?? true

        // Step 1: Collect DOIs from the chosen source
        var dois: [String] = []
        var sourceDescription: String = ""

        switch source {
        case "orcid":
            guard let orcidId = orcidId, !orcidId.isEmpty else {
                return CallTool.Result(content: [.text("orcid_id is required for source 'orcid'")], isError: true)
            }
            let works = try await orcid.getPublications(orcidId: orcidId)
            dois = works.compactMap(\.doi)
            sourceDescription = "ORCID \(orcidId) (\(works.count) works, \(dois.count) with DOI)"

        case "openalex_orcid":
            guard let orcidId = orcidId, !orcidId.isEmpty else {
                return CallTool.Result(content: [.text("orcid_id is required for source 'openalex_orcid'")], isError: true)
            }
            let works = try await academic.getWorksByOrcid(orcid: orcidId)
            dois = works.compactMap(\.cleanDOI).filter { !$0.isEmpty }
            sourceDescription = "OpenAlex ORCID \(orcidId) (\(works.count) works, \(dois.count) with DOI)\n⚠️  OpenAlex may include false positives from author name disambiguation"

        case "dois":
            guard !doisParam.isEmpty else {
                return CallTool.Result(content: [.text("dois array is required for source 'dois'")], isError: true)
            }
            dois = doisParam
            sourceDescription = "Manual DOI list (\(dois.count) DOIs)"

        default:
            return CallTool.Result(content: [.text("Unknown source: '\(source)'. Use 'orcid', 'openalex_orcid', or 'dois'.")], isError: true)
        }

        if dois.isEmpty {
            return CallTool.Result(content: [.text("No DOIs found from source: \(sourceDescription)")], isError: false)
        }

        // Deduplicate DOIs (some sources may have duplicates, e.g. preprint versions)
        var seen = Set<String>()
        dois = dois.filter { doi in
            let normalized = doi.lowercased()
                .replacingOccurrences(of: "https://doi.org/", with: "")
                .replacingOccurrences(of: "http://doi.org/", with: "")
            return seen.insert(normalized).inserted
        }

        // Step 2: Check which DOIs already exist in Zotero
        var existingDOIs = Set<String>()
        if skipExisting {
            for doi in dois {
                if let _ = try? reader.searchByDOI(doi: doi) {
                    existingDOIs.insert(doi.lowercased()
                        .replacingOccurrences(of: "https://doi.org/", with: "")
                        .replacingOccurrences(of: "http://doi.org/", with: ""))
                }
            }
        }

        let newDOIs = dois.filter { doi in
            let normalized = doi.lowercased()
                .replacingOccurrences(of: "https://doi.org/", with: "")
                .replacingOccurrences(of: "http://doi.org/", with: "")
            return !existingDOIs.contains(normalized)
        }

        // Step 3: Build report
        var lines: [String] = []
        lines.append("Source: \(sourceDescription)")
        lines.append("Total DOIs: \(dois.count)")
        if skipExisting {
            lines.append("Already in Zotero: \(existingDOIs.count) (will skip)")
        }
        lines.append("To import: \(newDOIs.count)")
        lines.append("")

        if dryRun {
            // Dry run: just list what would be imported
            lines.insert("=== DRY RUN (preview only) ===", at: 0)

            if !existingDOIs.isEmpty {
                lines.append("--- Already in Zotero (skipping) ---")
                for doi in dois {
                    let normalized = doi.lowercased()
                        .replacingOccurrences(of: "https://doi.org/", with: "")
                        .replacingOccurrences(of: "http://doi.org/", with: "")
                    if existingDOIs.contains(normalized) {
                        lines.append("  ✓ \(doi)")
                    }
                }
                lines.append("")
            }

            if !newDOIs.isEmpty {
                lines.append("--- Will import ---")
                for (i, doi) in newDOIs.enumerated() {
                    // Try to get metadata preview from OpenAlex
                    if let work = try? await academic.getWork(doi: doi) {
                        let authors = work.authorList.prefix(3).joined(separator: ", ")
                        let etAl = (work.authorList.count > 3) ? " et al." : ""
                        let year = work.publication_year != nil ? "(\(work.publication_year!))" : "(n.d.)"
                        lines.append("  \(i + 1). \(work.display_name ?? work.title ?? "(untitled)") — \(authors)\(etAl) \(year)")
                        lines.append("     DOI: \(doi)")
                    } else {
                        lines.append("  \(i + 1). DOI: \(doi) (metadata not found in OpenAlex)")
                    }
                }
            }

            if let ck = collectionKey {
                lines.append("\nWill add to collection: \(ck)")
            }
            if !tags.isEmpty {
                lines.append("Will apply tags: \(tags.joined(separator: ", "))")
            }
            lines.append("\nTo execute, call again with dry_run: false")
            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
        }

        // Step 4: Actually import (dry_run == false)
        guard webAPI != nil else {
            return CallTool.Result(
                content: [.text("Write operations require ZOTERO_API_KEY environment variable. Get your key at https://www.zotero.org/settings/keys/new")],
                isError: true
            )
        }
        let api = webAPI!

        var imported = 0
        var failed = 0
        var results: [(doi: String, status: String)] = []
        let collectionKeys = collectionKey != nil ? [collectionKey!] : []

        for doi in newDOIs {
            do {
                let result = try await api.addItemByDOI(
                    doi: doi,
                    collectionKeys: collectionKeys,
                    tags: tags,
                    resolver: doiResolver
                )
                imported += 1
                results.append((doi: doi, status: "✅ \(result.summary)"))
            } catch {
                failed += 1
                results.append((doi: doi, status: "❌ \(error.localizedDescription)"))
            }
        }

        lines.append("--- Import Results ---")
        for r in results {
            lines.append(r.status)
        }
        lines.append("")
        lines.append("Imported: \(imported), Failed: \(failed), Skipped: \(existingDOIs.count)")
        if imported > 0 {
            lines.append("Note: Zotero desktop will sync on next cycle to reflect changes locally.")
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Notes & Annotations Handlers

    private func handleGetNotes(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let itemKey = params.arguments?["item_key"]?.stringValue ?? ""

        let notes = try reader.getNotes(itemKey: itemKey)

        if notes.isEmpty {
            return CallTool.Result(content: [.text("No notes found for item: \(itemKey)")], isError: false)
        }

        var lines = ["Notes for \(itemKey) (\(notes.count)):"]
        for (i, note) in notes.enumerated() {
            let title = note.title.isEmpty ? "(untitled note)" : note.title
            lines.append("\n--- Note \(i + 1): \(title) [key: \(note.key)] ---")
            lines.append(note.content)
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    private func handleGetAnnotations(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let itemKey = params.arguments?["item_key"]?.stringValue ?? ""

        let annotations = try reader.getAnnotations(itemKey: itemKey)

        if annotations.isEmpty {
            return CallTool.Result(content: [.text("No annotations found for item: \(itemKey)")], isError: false)
        }

        var lines = ["Annotations for \(itemKey) (\(annotations.count)):"]
        for (i, a) in annotations.enumerated() {
            let page = a.pageLabel.isEmpty ? "" : " (p.\(a.pageLabel))"
            lines.append("\n\(i + 1). [\(a.type)]\(page) \(a.color.isEmpty ? "" : "[\(a.color)]")")
            if !a.text.isEmpty {
                lines.append("   Text: \(a.text)")
            }
            if !a.comment.isEmpty {
                lines.append("   Comment: \(a.comment)")
            }
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Write Handlers (Web API)

    private func requireWebAPI() -> CallTool.Result? {
        if webAPI == nil {
            return CallTool.Result(
                content: [.text("Write operations require ZOTERO_API_KEY environment variable. Get your key at https://www.zotero.org/settings/keys/new — then restart with: ZOTERO_API_KEY=your_key")],
                isError: true
            )
        }
        return nil
    }

    private func handleCreateCollection(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        if let err = requireWebAPI() { return err }
        let api = webAPI!

        let name = params.arguments?["name"]?.stringValue ?? ""
        let parentKey = params.arguments?["parent_key"]?.stringValue

        let result = try await api.createCollection(name: name, parentKey: parentKey)

        var text = "Collection created: \"\(name)\" [key: \(result.key)]"
        if let pk = parentKey {
            text += " (sub-collection of \(pk))"
        }
        text += "\nNote: Zotero desktop will sync on next cycle to reflect this change locally."
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    private func handleAddItemByDOI(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        if let err = requireWebAPI() { return err }
        let api = webAPI!

        let doi = params.arguments?["doi"]?.stringValue ?? ""
        let collectionKeys = extractStringArray(params.arguments?["collection_keys"])
        let tags = extractStringArray(params.arguments?["tags"])

        let result = try await api.addItemByDOI(
            doi: doi,
            collectionKeys: collectionKeys,
            tags: tags,
            resolver: doiResolver
        )

        var text = "Item added to Zotero: \(result.summary)"
        if !collectionKeys.isEmpty {
            text += "\nAdded to collections: \(collectionKeys.joined(separator: ", "))"
        }
        if !tags.isEmpty {
            text += "\nTags: \(tags.joined(separator: ", "))"
        }
        text += "\nNote: Zotero desktop will sync on next cycle to reflect this change locally."
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    private func handleCreateItem(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        if let err = requireWebAPI() { return err }
        let api = webAPI!

        let itemType = params.arguments?["item_type"]?.stringValue ?? "journalArticle"
        let title = params.arguments?["title"]?.stringValue ?? ""
        let doi = params.arguments?["doi"]?.stringValue
        let publicationTitle = params.arguments?["publication_title"]?.stringValue
        let date = params.arguments?["date"]?.stringValue
        let abstract = params.arguments?["abstract"]?.stringValue
        let collectionKeys = extractStringArray(params.arguments?["collection_keys"])
        let tags = extractStringArray(params.arguments?["tags"])

        // Parse creators from JSON array
        var creators: [ZoteroAPICreator] = []
        if let creatorsValue = params.arguments?["creators"],
           case .array(let creatorsArray) = creatorsValue {
            for creatorValue in creatorsArray {
                if case .object(let dict) = creatorValue {
                    let firstName = dict["firstName"]?.stringValue
                    let lastName = dict["lastName"]?.stringValue
                    if firstName != nil || lastName != nil {
                        creators.append(ZoteroAPICreator(firstName: firstName, lastName: lastName))
                    }
                }
            }
        }

        var itemData: [String: Any] = [
            "itemType": itemType,
            "title": title,
        ]

        if !creators.isEmpty {
            itemData["creators"] = creators.map { c -> [String: Any] in
                var d: [String: Any] = ["creatorType": c.creatorType]
                if let fn = c.firstName { d["firstName"] = fn }
                if let ln = c.lastName { d["lastName"] = ln }
                return d
            }
        }
        if let v = doi { itemData["DOI"] = v }
        if let v = publicationTitle { itemData["publicationTitle"] = v }
        if let v = date { itemData["date"] = v }
        if let v = abstract { itemData["abstractNote"] = v }
        if !tags.isEmpty { itemData["tags"] = tags.map { ["tag": $0] } }
        if !collectionKeys.isEmpty { itemData["collections"] = collectionKeys }

        let result = try await api.createItem(itemData)

        var text = "Item created: \"\(title)\" [\(itemType)] [key: \(result.key)]"
        if !collectionKeys.isEmpty {
            text += "\nIn collections: \(collectionKeys.joined(separator: ", "))"
        }
        text += "\nNote: Zotero desktop will sync on next cycle to reflect this change locally."
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    private func handleAddToCollection(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        if let err = requireWebAPI() { return err }
        let api = webAPI!

        let itemKey = params.arguments?["item_key"]?.stringValue ?? ""
        let collectionKey = params.arguments?["collection_key"]?.stringValue ?? ""

        // Get current version from API
        let version = try await api.getItemVersion(itemKey: itemKey)

        // Get current collections for the item (from local SQLite), add the new one
        let currentCollections = try reader.getItemCollectionKeys(itemKey: itemKey)
        var updatedCollections = currentCollections
        if !updatedCollections.contains(collectionKey) {
            updatedCollections.append(collectionKey)
        }

        try await api.addItemToCollection(itemKey: itemKey, collectionKeys: updatedCollections, currentVersion: version)

        return CallTool.Result(
            content: [.text("Item \(itemKey) added to collection \(collectionKey).\nNote: Zotero desktop will sync on next cycle.")],
            isError: false
        )
    }

    // MARK: - Formatting Helpers

    private func formatItems(_ items: [ZoteroItem], header: String) -> String {
        if items.isEmpty { return "\(header): no results." }

        var lines = ["\(header) (\(items.count)):"]
        for (i, item) in items.enumerated() {
            let creators = item.creators.isEmpty ? "" : " — \(item.creators.joined(separator: ", "))"
            let date = item.date ?? "n.d."
            lines.append("\(i + 1). [\(item.itemType)] \(item.title)\(creators) (\(date)) [key: \(item.key)]")
        }
        return lines.joined(separator: "\n")
    }

    private func formatItemDetail(_ item: ZoteroItem) -> String {
        var lines: [String] = []
        lines.append("Title: \(item.title)")
        lines.append("Type: \(item.itemType)")
        lines.append("Key: \(item.key)")
        if !item.creators.isEmpty {
            lines.append("Creators: \(item.creators.joined(separator: "; "))")
        }
        if let date = item.date { lines.append("Date: \(date)") }
        if let pub = item.publicationTitle { lines.append("Publication: \(pub)") }
        if let doi = item.DOI { lines.append("DOI: \(doi)") }
        if let url = item.url { lines.append("URL: \(url)") }
        if !item.tags.isEmpty { lines.append("Tags: \(item.tags.joined(separator: ", "))") }
        if !item.collections.isEmpty { lines.append("Collections: \(item.collections.joined(separator: ", "))") }
        lines.append("Date Added: \(item.dateAdded)")
        if let abstract = item.abstractNote, !abstract.isEmpty {
            lines.append("\nAbstract:\n\(abstract)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Value Helpers

/// Safely extract Int from a Value that might be .int or .double
private func intFromValue(_ value: Value?) -> Int? {
    guard let value = value else { return nil }
    return Int(value, strict: false)
}

/// Extract an array of strings from a Value (handles JSON array of strings).
private func extractStringArray(_ value: Value?) -> [String] {
    guard let value = value, case .array(let arr) = value else { return [] }
    return arr.compactMap(\.stringValue)
}
