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

    public init() async throws {
        reader = try ZoteroReader()
        embeddings = EmbeddingManager()
        academic = AcademicSearchClient()
        tools = Self.defineTools()

        server = Server(
            name: "che-zotero-mcp",
            version: "1.0.0",
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

    private static func defineTools() -> [Tool] {
        [
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
        ]
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
