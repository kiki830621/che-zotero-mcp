// Sources/CheZoteroMCPCore/ZoteroReader.swift
//
// Reads Zotero's local SQLite database (read-only).
// Default path: ~/Zotero/zotero.sqlite
//
// Zotero schema key tables:
//   items → itemData → itemDataValues + fields (metadata)
//   itemCreators → creators (authors)
//   collections, collectionItems (collections)
//   tags, itemTags (tags)
//   itemAttachments (PDF paths)

import Foundation
import SQLite3

// MARK: - Data Models

public struct ZoteroItem {
    public let key: String
    public let itemType: String
    public let title: String
    public let creators: [String]      // "FirstName LastName"
    public let abstractNote: String?
    public let date: String?
    public let publicationTitle: String?
    public let DOI: String?
    public let url: String?
    public let tags: [String]
    public let collections: [String]   // collection names
    public let dateAdded: String
    public let dateModified: String

    /// Text representation for embedding: title + creators + abstract + tags
    public var searchableText: String {
        var parts = [title]
        if !creators.isEmpty {
            parts.append(creators.joined(separator: ", "))
        }
        if let abstract = abstractNote, !abstract.isEmpty {
            parts.append(abstract)
        }
        if !tags.isEmpty {
            parts.append(tags.joined(separator: " "))
        }
        if let pub = publicationTitle, !pub.isEmpty {
            parts.append(pub)
        }
        return parts.joined(separator: "\n")
    }
}

public struct ZoteroCollection {
    public let key: String
    public let name: String
    public let parentKey: String?
    public let itemCount: Int
}

// MARK: - ZoteroReader

public class ZoteroReader {
    private var db: OpaquePointer?
    private let dbPath: String

    // Excluded item types: annotation(1), attachment(3), note(28)
    private static let excludedTypeIDs = [1, 3, 28]

    public init(dbPath: String? = nil) throws {
        self.dbPath = dbPath ?? Self.defaultDatabasePath()

        guard FileManager.default.fileExists(atPath: self.dbPath) else {
            throw ZoteroError.databaseNotFound(self.dbPath)
        }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(self.dbPath, &db, flags, nil)
        guard result == SQLITE_OK else {
            throw ZoteroError.cannotOpenDatabase(String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private static func defaultDatabasePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Zotero/zotero.sqlite"
    }

    // MARK: - Search

    /// Search items by keyword in title, creator names, and tags.
    public func search(query: String, limit: Int = 10) throws -> [ZoteroItem] {
        let pattern = "%\(query)%"

        let sql = """
            SELECT DISTINCT i.itemID, i.key, it.typeName, i.dateAdded, i.dateModified
            FROM items i
            JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
            WHERE i.itemTypeID NOT IN (\(Self.excludedTypeIDs.map(String.init).joined(separator: ",")))
            AND (
                i.itemID IN (
                    SELECT id.itemID FROM itemData id
                    JOIN fields f ON id.fieldID = f.fieldID
                    JOIN itemDataValues idv ON id.valueID = idv.valueID
                    WHERE f.fieldName IN ('title', 'abstractNote') AND idv.value LIKE ?1
                )
                OR i.itemID IN (
                    SELECT ic.itemID FROM itemCreators ic
                    JOIN creators c ON ic.creatorID = c.creatorID
                    WHERE c.firstName LIKE ?1 OR c.lastName LIKE ?1
                )
                OR i.itemID IN (
                    SELECT it2.itemID FROM itemTags it2
                    JOIN tags t ON it2.tagID = t.tagID
                    WHERE t.name LIKE ?1
                )
            )
            ORDER BY i.dateModified DESC
            LIMIT ?2
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var itemIDs: [(itemID: Int, key: String, typeName: String, dateAdded: String, dateModified: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = Int(sqlite3_column_int(stmt, 0))
            let key = String(cString: sqlite3_column_text(stmt, 1))
            let typeName = String(cString: sqlite3_column_text(stmt, 2))
            let dateAdded = String(cString: sqlite3_column_text(stmt, 3))
            let dateModified = String(cString: sqlite3_column_text(stmt, 4))
            itemIDs.append((itemID, key, typeName, dateAdded, dateModified))
        }

        return try itemIDs.map { try buildItem(itemID: $0.itemID, key: $0.key, typeName: $0.typeName, dateAdded: $0.dateAdded, dateModified: $0.dateModified) }
    }

    // MARK: - Get Single Item

    /// Get metadata for a single item by its key.
    public func getItem(key: String) throws -> ZoteroItem? {
        let sql = """
            SELECT i.itemID, i.key, it.typeName, i.dateAdded, i.dateModified
            FROM items i
            JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
            WHERE i.key = ?1
            AND i.itemTypeID NOT IN (\(Self.excludedTypeIDs.map(String.init).joined(separator: ",")))
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let itemID = Int(sqlite3_column_int(stmt, 0))
        let itemKey = String(cString: sqlite3_column_text(stmt, 1))
        let typeName = String(cString: sqlite3_column_text(stmt, 2))
        let dateAdded = String(cString: sqlite3_column_text(stmt, 3))
        let dateModified = String(cString: sqlite3_column_text(stmt, 4))

        return try buildItem(itemID: itemID, key: itemKey, typeName: typeName, dateAdded: dateAdded, dateModified: dateModified)
    }

    // MARK: - Collections

    /// List all collections.
    public func getCollections() throws -> [ZoteroCollection] {
        let sql = """
            SELECT c.key, c.collectionName, pc.key as parentKey,
                   (SELECT COUNT(*) FROM collectionItems ci WHERE ci.collectionID = c.collectionID) as itemCount
            FROM collections c
            LEFT JOIN collections pc ON c.parentCollectionID = pc.collectionID
            ORDER BY c.collectionName
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [ZoteroCollection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let parentKey = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 2)) : nil
            let count = Int(sqlite3_column_int(stmt, 3))
            results.append(ZoteroCollection(key: key, name: name, parentKey: parentKey, itemCount: count))
        }
        return results
    }

    // MARK: - Tags

    /// List all tags with usage count.
    public func getTags() throws -> [(name: String, count: Int)] {
        let sql = """
            SELECT t.name, COUNT(it.itemID) as cnt
            FROM tags t
            JOIN itemTags it ON t.tagID = it.tagID
            GROUP BY t.tagID
            ORDER BY cnt DESC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(name: String, count: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            results.append((name: name, count: count))
        }
        return results
    }

    // MARK: - Recent Items

    /// Get recently added items.
    public func getRecent(limit: Int = 10) throws -> [ZoteroItem] {
        let sql = """
            SELECT i.itemID, i.key, it.typeName, i.dateAdded, i.dateModified
            FROM items i
            JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
            WHERE i.itemTypeID NOT IN (\(Self.excludedTypeIDs.map(String.init).joined(separator: ",")))
            ORDER BY i.dateAdded DESC
            LIMIT ?1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var itemIDs: [(itemID: Int, key: String, typeName: String, dateAdded: String, dateModified: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = Int(sqlite3_column_int(stmt, 0))
            let key = String(cString: sqlite3_column_text(stmt, 1))
            let typeName = String(cString: sqlite3_column_text(stmt, 2))
            let dateAdded = String(cString: sqlite3_column_text(stmt, 3))
            let dateModified = String(cString: sqlite3_column_text(stmt, 4))
            itemIDs.append((itemID, key, typeName, dateAdded, dateModified))
        }

        return try itemIDs.map { try buildItem(itemID: $0.itemID, key: $0.key, typeName: $0.typeName, dateAdded: $0.dateAdded, dateModified: $0.dateModified) }
    }

    // MARK: - Items in Collection

    /// Get all items in a specific collection by collection key.
    public func getItemsInCollection(collectionKey: String, limit: Int = 50) throws -> [ZoteroItem] {
        let sql = """
            SELECT i.itemID, i.key, it.typeName, i.dateAdded, i.dateModified
            FROM items i
            JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
            JOIN collectionItems ci ON ci.itemID = i.itemID
            JOIN collections c ON ci.collectionID = c.collectionID
            WHERE c.key = ?1
            AND i.itemTypeID NOT IN (\(Self.excludedTypeIDs.map(String.init).joined(separator: ",")))
            ORDER BY i.dateModified DESC
            LIMIT ?2
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var itemIDs: [(itemID: Int, key: String, typeName: String, dateAdded: String, dateModified: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = Int(sqlite3_column_int(stmt, 0))
            let key = String(cString: sqlite3_column_text(stmt, 1))
            let typeName = String(cString: sqlite3_column_text(stmt, 2))
            let dateAdded = String(cString: sqlite3_column_text(stmt, 3))
            let dateModified = String(cString: sqlite3_column_text(stmt, 4))
            itemIDs.append((itemID, key, typeName, dateAdded, dateModified))
        }

        return try itemIDs.map { try buildItem(itemID: $0.itemID, key: $0.key, typeName: $0.typeName, dateAdded: $0.dateAdded, dateModified: $0.dateModified) }
    }

    // MARK: - Search by DOI

    /// Search for an item by DOI.
    public func searchByDOI(doi: String) throws -> ZoteroItem? {
        let cleanDOI = doi
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")

        let sql = """
            SELECT i.itemID, i.key, it.typeName, i.dateAdded, i.dateModified
            FROM items i
            JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
            JOIN itemData id ON i.itemID = id.itemID
            JOIN fields f ON id.fieldID = f.fieldID
            JOIN itemDataValues idv ON id.valueID = idv.valueID
            WHERE f.fieldName = 'DOI' AND idv.value = ?1
            AND i.itemTypeID NOT IN (\(Self.excludedTypeIDs.map(String.init).joined(separator: ",")))
            LIMIT 1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, cleanDOI, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let itemID = Int(sqlite3_column_int(stmt, 0))
        let key = String(cString: sqlite3_column_text(stmt, 1))
        let typeName = String(cString: sqlite3_column_text(stmt, 2))
        let dateAdded = String(cString: sqlite3_column_text(stmt, 3))
        let dateModified = String(cString: sqlite3_column_text(stmt, 4))

        return try buildItem(itemID: itemID, key: key, typeName: typeName, dateAdded: dateAdded, dateModified: dateModified)
    }

    // MARK: - Attachments

    /// Get attachment file paths for an item.
    public func getAttachments(itemKey: String) throws -> [(key: String, filename: String, contentType: String, path: String?)] {
        // First get the itemID for the parent item
        let parentSQL = "SELECT itemID FROM items WHERE key = ?1"

        var parentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, parentSQL, -1, &parentStmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(parentStmt) }

        sqlite3_bind_text(parentStmt, 1, itemKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(parentStmt) == SQLITE_ROW else { return [] }
        let parentItemID = Int(sqlite3_column_int(parentStmt, 0))

        // Get attachments for this parent item
        let sql = """
            SELECT i.key, ia.contentType, ia.path
            FROM itemAttachments ia
            JOIN items i ON ia.itemID = i.itemID
            WHERE ia.parentItemID = ?1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(parentItemID))

        let storagePath = (dbPath as NSString).deletingLastPathComponent + "/storage"
        var results: [(key: String, filename: String, contentType: String, path: String?)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let attachmentKey = String(cString: sqlite3_column_text(stmt, 0))
            let contentType = sqlite3_column_type(stmt, 1) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 1)) : "unknown"
            let rawPath = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 2)) : nil

            // Zotero stores paths as "storage:filename.pdf"
            var filename = rawPath ?? ""
            var fullPath: String? = nil
            if let raw = rawPath, raw.hasPrefix("storage:") {
                filename = String(raw.dropFirst("storage:".count))
                fullPath = "\(storagePath)/\(attachmentKey)/\(filename)"
            }

            results.append((key: attachmentKey, filename: filename, contentType: contentType, path: fullPath))
        }

        return results
    }

    // MARK: - Get All Items (for building embedding index)

    /// Get all library items. Used to build the semantic search index.
    public func getAllItems() throws -> [ZoteroItem] {
        let sql = """
            SELECT i.itemID, i.key, it.typeName, i.dateAdded, i.dateModified
            FROM items i
            JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
            WHERE i.itemTypeID NOT IN (\(Self.excludedTypeIDs.map(String.init).joined(separator: ",")))
            ORDER BY i.dateAdded DESC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var itemIDs: [(itemID: Int, key: String, typeName: String, dateAdded: String, dateModified: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = Int(sqlite3_column_int(stmt, 0))
            let key = String(cString: sqlite3_column_text(stmt, 1))
            let typeName = String(cString: sqlite3_column_text(stmt, 2))
            let dateAdded = String(cString: sqlite3_column_text(stmt, 3))
            let dateModified = String(cString: sqlite3_column_text(stmt, 4))
            itemIDs.append((itemID, key, typeName, dateAdded, dateModified))
        }

        return try itemIDs.map { try buildItem(itemID: $0.itemID, key: $0.key, typeName: $0.typeName, dateAdded: $0.dateAdded, dateModified: $0.dateModified) }
    }

    // MARK: - Private Helpers

    /// Build a full ZoteroItem from an itemID.
    private func buildItem(itemID: Int, key: String, typeName: String, dateAdded: String, dateModified: String) throws -> ZoteroItem {
        let fields = try getItemFields(itemID: itemID)
        let creators = try getItemCreators(itemID: itemID)
        let tags = try getItemTags(itemID: itemID)
        let collections = try getItemCollections(itemID: itemID)

        return ZoteroItem(
            key: key,
            itemType: typeName,
            title: fields["title"] ?? "(untitled)",
            creators: creators,
            abstractNote: fields["abstractNote"],
            date: fields["date"],
            publicationTitle: fields["publicationTitle"],
            DOI: fields["DOI"],
            url: fields["url"],
            tags: tags,
            collections: collections,
            dateAdded: dateAdded,
            dateModified: dateModified
        )
    }

    /// Get all field values for an item.
    private func getItemFields(itemID: Int) throws -> [String: String] {
        let sql = """
            SELECT f.fieldName, idv.value
            FROM itemData id
            JOIN fields f ON id.fieldID = f.fieldID
            JOIN itemDataValues idv ON id.valueID = idv.valueID
            WHERE id.itemID = ?1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(itemID))

        var fields: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let value = String(cString: sqlite3_column_text(stmt, 1))
            fields[name] = value
        }
        return fields
    }

    /// Get creators for an item as "FirstName LastName" strings.
    private func getItemCreators(itemID: Int) throws -> [String] {
        let sql = """
            SELECT c.firstName, c.lastName
            FROM itemCreators ic
            JOIN creators c ON ic.creatorID = c.creatorID
            WHERE ic.itemID = ?1
            ORDER BY ic.orderIndex
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(itemID))

        var creators: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let firstName = String(cString: sqlite3_column_text(stmt, 0))
            let lastName = String(cString: sqlite3_column_text(stmt, 1))
            let name = firstName.isEmpty ? lastName : "\(firstName) \(lastName)"
            creators.append(name)
        }
        return creators
    }

    /// Get tags for an item.
    private func getItemTags(itemID: Int) throws -> [String] {
        let sql = """
            SELECT t.name
            FROM itemTags it
            JOIN tags t ON it.tagID = t.tagID
            WHERE it.itemID = ?1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(itemID))

        var tags: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            tags.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return tags
    }

    /// Get collection names for an item.
    private func getItemCollections(itemID: Int) throws -> [String] {
        let sql = """
            SELECT c.collectionName
            FROM collectionItems ci
            JOIN collections c ON ci.collectionID = c.collectionID
            WHERE ci.itemID = ?1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ZoteroError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(itemID))

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return names
    }
}

// MARK: - Error Types

public enum ZoteroError: Error, LocalizedError {
    case databaseNotFound(String)
    case cannotOpenDatabase(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return "Zotero database not found at: \(path)"
        case .cannotOpenDatabase(let msg):
            return "Cannot open Zotero database: \(msg)"
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        }
    }
}
