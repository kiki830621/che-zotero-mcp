// Server+ZoteroHandlers.swift — Zotero local read handlers
import Foundation
import MCP

extension CheZoteroMCPServer {

    // MARK: - Group ID Resolution

    /// Resolve group_id parameter to internal libraryID for SQLite queries.
    func resolveLibraryID(from params: CallTool.Parameters) throws -> Int? {
        guard let groupId = intFromValue(params.arguments?["group_id"]) else {
            return nil  // personal library (no filter)
        }
        guard let libraryID = try reader.resolveLibraryID(groupID: groupId) else {
            throw ZoteroError.queryFailed("Group not found: \(groupId). Use zotero_list_groups to see available groups.")
        }
        return libraryID
    }

    /// Resolve group_id parameter to LibraryTarget for Web API calls.
    func resolveLibraryTarget(from params: CallTool.Parameters) -> LibraryTarget {
        guard let groupId = intFromValue(params.arguments?["group_id"]) else {
            return .user
        }
        return .group(groupId)
    }

    // MARK: - Group Handlers

    func handleListGroups() throws -> CallTool.Result {
        let groups = try reader.getGroups()

        if groups.isEmpty {
            return CallTool.Result(content: [.text("No group libraries found. You only have a personal library.")], isError: false)
        }

        var lines = ["Group libraries (\(groups.count)):"]
        for g in groups {
            lines.append("- \(g.name) [group_id: \(g.groupID)]")
        }
        lines.append("\nUse the group_id with other tools (e.g., zotero_search, zotero_get_collections) to operate on a group library.")
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Zotero Handlers

    func handleSearch(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let query = params.arguments?["query"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10
        let libraryID = try resolveLibraryID(from: params)

        let items = try reader.search(query: query, limit: limit, libraryID: libraryID)
        let groupLabel = libraryID != nil ? " (group library)" : ""
        let text = formatItems(items, header: "Search results for '\(query)'\(groupLabel)")
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    func handleGetMyPublications(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let limit = intFromValue(params.arguments?["limit"]) ?? 100

        // Try local SQLite first; fallback to Web API if database is locked
        do {
            let items = try reader.getMyPublications(limit: limit)
            let text = formatItems(items, header: "My Publications") + "\n\n[Source: local]"
            return CallTool.Result(content: [.text(text)], isError: false)
        } catch let error where error.localizedDescription.contains("locked") {
            // Database locked (Zotero is running) — fallback to Web API
            guard let api = webAPI else {
                return CallTool.Result(
                    content: [.text("Zotero database is locked (Zotero desktop is running). To use Web API fallback, set the ZOTERO_API_KEY environment variable. Or close Zotero and try again.")],
                    isError: true
                )
            }

            let apiItems = try await api.getMyPublications(limit: limit)

            if apiItems.isEmpty {
                return CallTool.Result(content: [.text("No items in My Publications.\n\n[Source: web — Zotero is running]")], isError: false)
            }

            var lines = ["My Publications (\(apiItems.count)):"]
            for (i, item) in apiItems.enumerated() {
                let title = item.data.title ?? "(untitled)"
                let creators = item.data.creators?.compactMap { c in
                    if let name = c.name { return name }
                    return [c.firstName, c.lastName].compactMap { $0 }.joined(separator: " ")
                }.joined(separator: ", ") ?? ""
                let date = item.data.date ?? ""
                lines.append("\(i + 1). [\(item.data.itemType)] \(title) — \(creators) (\(date)) [key: \(item.key)]")
            }
            lines.append("\n[Source: web — Zotero is running, used Web API fallback]")
            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
        }
    }

    func handleGetMetadata(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let itemKey = params.arguments?["item_key"]?.stringValue ?? ""

        guard let item = try reader.getItem(key: itemKey) else {
            return CallTool.Result(content: [.text("Item not found: \(itemKey)")], isError: true)
        }

        let text = formatItemDetail(item)
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    func handleGetCollections(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let libraryID = try resolveLibraryID(from: params)
        let collections = try reader.getCollections(libraryID: libraryID)

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

    func handleGetTags(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let libraryID = try resolveLibraryID(from: params)
        let tags = try reader.getTags(libraryID: libraryID)

        if tags.isEmpty {
            return CallTool.Result(content: [.text("No tags found.")], isError: false)
        }

        var lines = ["Tags (\(tags.count)):"]
        for t in tags {
            lines.append("- \(t.name) (\(t.count) items)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    func handleGetRecent(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let limit = intFromValue(params.arguments?["limit"]) ?? 10
        let libraryID = try resolveLibraryID(from: params)
        let items = try reader.getRecent(limit: limit, libraryID: libraryID)
        let groupLabel = libraryID != nil ? " (group library)" : ""
        let text = formatItems(items, header: "Recent \(items.count) items\(groupLabel)")
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    func handleSemanticSearch(_ params: CallTool.Parameters) async throws -> CallTool.Result {
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

    func handleBuildIndex() async throws -> CallTool.Result {
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

    func handleGetItemsInCollection(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let collectionKey = params.arguments?["collection_key"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 50

        let items = try reader.getItemsInCollection(collectionKey: collectionKey, limit: limit)
        let text = formatItems(items, header: "Items in collection '\(collectionKey)'")
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    func handleSearchByDOI(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let doi = params.arguments?["doi"]?.stringValue ?? ""
        let libraryID = try resolveLibraryID(from: params)

        guard let item = try reader.searchByDOI(doi: doi, libraryID: libraryID) else {
            return CallTool.Result(content: [.text("No item found with DOI: \(doi)")], isError: false)
        }

        let text = formatItemDetail(item)
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    func handleGetAttachments(_ params: CallTool.Parameters) throws -> CallTool.Result {
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

    func handleGetNotes(_ params: CallTool.Parameters) throws -> CallTool.Result {
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

    func handleGetAnnotations(_ params: CallTool.Parameters) throws -> CallTool.Result {
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
}
