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

    func handleDeleteCollection(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        if let err = requireWebAPI() { return err }
        let api = webAPI!

        let collectionKey = params.arguments?["collection_key"]?.stringValue ?? ""

        let version = try await api.getCollectionVersion(collectionKey: collectionKey)
        try await api.deleteCollection(collectionKey: collectionKey, version: version)

        return CallTool.Result(
            content: [.text("Collection deleted: \(collectionKey)\nItems inside were NOT deleted — only the collection container was removed.\nNote: Zotero desktop will sync on next cycle.")],
            isError: false
        )
    }

    func handleNormalizeTitles(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        if let err = requireWebAPI() { return err }
        let api = webAPI!

        let dryRun = params.arguments?["dry_run"]?.boolValue ?? true

        // Resolve items
        var items: [ZoteroItem] = []
        if let keysValue = params.arguments?["item_keys"],
           case .array(let keysArray) = keysValue {
            let keys = keysArray.compactMap(\.stringValue)
            items = try keys.compactMap { try reader.getItem(key: $0) }
        } else if let collKey = params.arguments?["collection_key"]?.stringValue, !collKey.isEmpty {
            items = try reader.getItemsInCollection(collectionKey: collKey, limit: 500)
        }

        if items.isEmpty {
            return CallTool.Result(
                content: [.text("No items found. Provide item_keys or collection_key.")],
                isError: true
            )
        }

        let results = TitleNormalizer.normalizeBatch(items)
        let changed = results.filter { $0.changed }

        if changed.isEmpty {
            return CallTool.Result(
                content: [.text("All \(items.count) titles are already in sentence case. No changes needed.")],
                isError: false
            )
        }

        var output: [String] = []
        output.append("## Title Normalization \(dryRun ? "(DRY RUN)" : "(APPLIED)")")
        output.append("Items scanned: \(items.count)")
        output.append("Titles to change: \(changed.count)")
        output.append("Already sentence case: \(items.count - changed.count)")
        output.append("")

        var writeErrors: [String] = []

        for result in changed {
            output.append("### [\(result.itemKey)]")
            output.append("  Before: \(result.originalTitle)")
            output.append("  After:  \(result.normalizedTitle)")
            if !result.protectedWords.isEmpty {
                output.append("  Protected: \(result.protectedWords.joined(separator: ", "))")
            }

            if !dryRun {
                do {
                    let version = try await api.getItemVersion(itemKey: result.itemKey)
                    let body: [String: Any] = ["title": result.normalizedTitle]
                    try await api.patchItem(itemKey: result.itemKey, fields: body, version: version)
                    output.append("  Status: ✓ Updated")
                } catch {
                    output.append("  Status: ✗ Error: \(error.localizedDescription)")
                    writeErrors.append(result.itemKey)
                }
            }
            output.append("")
        }

        if !dryRun {
            output.append("---")
            output.append("Updated: \(changed.count - writeErrors.count) / \(changed.count)")
            if !writeErrors.isEmpty {
                output.append("Failed: \(writeErrors.joined(separator: ", "))")
            }
            output.append("Note: Zotero desktop will sync on next cycle to reflect changes locally.")
        } else {
            output.append("---")
            output.append("This is a preview. Set dry_run=false to apply changes via Zotero Web API.")
        }

        return CallTool.Result(content: [.text(output.joined(separator: "\n"))], isError: false)
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
