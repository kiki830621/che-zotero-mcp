// Server+WriteHandlers.swift — Zotero Web API write operation handlers
import Foundation
import MCP

extension CheZoteroMCPServer {

    func requireWebAPI() -> CallTool.Result? {
        if webAPI == nil {
            return CallTool.Result(
                content: [.text("Write operations require ZOTERO_API_KEY environment variable. Get your key at https://www.zotero.org/settings/keys/new — then restart with: ZOTERO_API_KEY=your_key")],
                isError: true
            )
        }
        return nil
    }

    func handleCreateCollection(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        if let err = requireWebAPI() { return err }
        let api = webAPI!

        let name = params.arguments?["name"]?.stringValue ?? ""
        let parentKey = params.arguments?["parent_key"]?.stringValue

        let result = try await api.createCollection(name: name, parentKey: parentKey)

        if result.isDuplicate {
            return CallTool.Result(
                content: [.text("Skipped (duplicate): collection \"\(name)\" already exists [key: \(result.key)]")],
                isError: false
            )
        }

        var text = "Collection created: \"\(name)\" [key: \(result.key)]"
        if let pk = parentKey {
            text += " (sub-collection of \(pk))"
        }
        text += "\nNote: Zotero desktop will sync on next cycle to reflect this change locally."
        return CallTool.Result(content: [.text(text)], isError: false)
    }

    func handleAddItemByDOI(_ params: CallTool.Parameters) async throws -> CallTool.Result {
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

        if result.isDuplicate {
            return CallTool.Result(
                content: [.text("Skipped (duplicate): \(result.summary)")],
                isError: false
            )
        }

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

    func handleCreateItem(_ params: CallTool.Parameters) async throws -> CallTool.Result {
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

        // Idempotency check: if DOI is provided, check if it already exists
        if let doi = doi, !doi.isEmpty {
            if let existing = try? await api.searchItemByDOI(doi: doi) {
                return CallTool.Result(
                    content: [.text("Skipped (duplicate): item with DOI \(doi) already exists [key: \(existing.key)]")],
                    isError: false
                )
            }
        }

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

    func handleAddToCollection(_ params: CallTool.Parameters) async throws -> CallTool.Result {
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

    func handleDeleteItem(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        if let err = requireWebAPI() { return err }
        let api = webAPI!

        let itemKey = params.arguments?["item_key"]?.stringValue ?? ""

        // Get current version (required for delete)
        let version = try await api.getItemVersion(itemKey: itemKey)
        try await api.deleteItem(itemKey: itemKey, version: version)

        return CallTool.Result(
            content: [.text("Item deleted: \(itemKey)\nNote: Zotero desktop will sync on next cycle to reflect this change locally.")],
            isError: false
        )
    }
}
