// Sources/CheZoteroMCPCore/ZoteroWebAPI.swift
//
// Zotero Web API v3 client for write operations.
// Requires ZOTERO_API_KEY environment variable.
// Read operations use ZoteroReader (local SQLite), write operations use this client.
// https://www.zotero.org/support/dev/web_api/v3/basics

import Foundation

// MARK: - Data Models

public struct ZoteroAPIItem: Codable {
    public let key: String
    public let version: Int
    public let data: ZoteroAPIItemData
}

public struct ZoteroAPIItemData: Codable {
    public let key: String
    public let version: Int
    public let itemType: String
    public let title: String?
    public let creators: [ZoteroAPICreator]?
    public let abstractNote: String?
    public let publicationTitle: String?
    public let date: String?
    public let DOI: String?
    public let url: String?
    public let volume: String?
    public let issue: String?
    public let pages: String?
    public let tags: [ZoteroAPITag]?
    public let collections: [String]?
}

public struct ZoteroAPICreator: Codable {
    public let creatorType: String
    public let firstName: String?
    public let lastName: String?
    public let name: String?  // for single-field names (e.g. institutions)

    public init(creatorType: String = "author", firstName: String?, lastName: String?, name: String? = nil) {
        self.creatorType = creatorType
        self.firstName = firstName
        self.lastName = lastName
        self.name = name
    }
}

public struct ZoteroAPITag: Codable {
    public let tag: String
    public let type: Int?

    public init(tag: String, type: Int? = nil) {
        self.tag = tag
        self.type = type
    }
}

public struct ZoteroAPICollection: Codable {
    public let key: String
    public let version: Int
    public let data: ZoteroAPICollectionData
}

public struct ZoteroAPICollectionData: Codable {
    public let key: String
    public let name: String
    public let parentCollection: ParentCollection?
    public let version: Int
}

// Zotero uses `false` for no parent or a string key for parent
public enum ParentCollection: Codable {
    case none
    case key(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let key = try? container.decode(String.self) {
            self = .key(key)
        } else if let val = try? container.decode(Bool.self), !val {
            self = .none
        } else {
            self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encode(false)
        case .key(let key):
            try container.encode(key)
        }
    }
}

// Write response envelope
struct WriteResponse: Codable {
    let successful: [String: WriteResponseItem]?
    let unchanged: [String: String]?
    let failed: [String: WriteResponseError]?
}

struct WriteResponseItem: Codable {
    let key: String
    let version: Int
    let data: [String: AnyCodable]?
}

struct WriteResponseError: Codable {
    let key: String?
    let code: Int
    let message: String
}

// MARK: - ZoteroWebAPI

public class ZoteroWebAPI {
    private let baseURL = "https://api.zotero.org"
    private let apiKey: String
    private let userId: Int
    private let session: URLSession

    /// Initialize with API key and auto-resolved userId.
    /// Use `ZoteroWebAPI.create(apiKey:)` for async initialization.
    private init(apiKey: String, userId: Int) {
        self.apiKey = apiKey
        self.userId = userId
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Create a ZoteroWebAPI instance, resolving userId from the API key.
    public static func create(apiKey: String) async throws -> ZoteroWebAPI {
        let userId = try await resolveUserId(apiKey: apiKey)
        return ZoteroWebAPI(apiKey: apiKey, userId: userId)
    }

    /// Create from environment variable ZOTERO_API_KEY.
    public static func createFromEnvironment() async throws -> ZoteroWebAPI {
        guard let apiKey = ProcessInfo.processInfo.environment["ZOTERO_API_KEY"],
              !apiKey.isEmpty else {
            throw ZoteroWebAPIError.missingAPIKey
        }
        return try await create(apiKey: apiKey)
    }

    // MARK: - User ID Resolution

    private static func resolveUserId(apiKey: String) async throws -> Int {
        let url = URL(string: "https://api.zotero.org/keys/\(apiKey)")!
        var request = URLRequest(url: url)
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        request.setValue(apiKey, forHTTPHeaderField: "Zotero-API-Key")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZoteroWebAPIError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            throw ZoteroWebAPIError.authenticationFailed("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = json["userID"] as? Int else {
            throw ZoteroWebAPIError.authenticationFailed("Cannot parse userId from key info")
        }

        return userId
    }

    // MARK: - Collections

    /// Create a new collection (idempotent: skips if same name exists at same level).
    public func createCollection(name: String, parentKey: String? = nil) async throws -> (key: String, version: Int, isDuplicate: Bool) {
        // Idempotency check: search for existing collection with same name at same level
        if let existing = try await findCollection(name: name, parentKey: parentKey) {
            return (key: existing.key, version: existing.version, isDuplicate: true)
        }

        var collectionData: [String: Any] = ["name": name]
        collectionData["parentCollection"] = parentKey ?? false

        let result = try await post(path: "/users/\(userId)/collections", body: [collectionData])

        guard let successful = result["successful"] as? [String: Any],
              let first = successful["0"] as? [String: Any],
              let key = first["key"] as? String,
              let version = first["version"] as? Int else {
            // Check for failure
            if let failed = result["failed"] as? [String: Any],
               let firstFail = failed["0"] as? [String: Any],
               let message = firstFail["message"] as? String {
                throw ZoteroWebAPIError.writeFailed(message)
            }
            throw ZoteroWebAPIError.writeFailed("Unknown error creating collection")
        }

        return (key: key, version: version, isDuplicate: false)
    }

    /// Find a collection by name and parent (for idempotency check).
    private func findCollection(name: String, parentKey: String?) async throws -> (key: String, version: Int)? {
        let url = URL(string: "\(baseURL)/users/\(userId)/collections")!
        var request = makeRequest(method: "GET", url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }

        guard let collections = try? JSONDecoder().decode([ZoteroAPICollection].self, from: data) else {
            return nil
        }

        let target = collections.first { c in
            guard c.data.name == name else { return false }
            switch (c.data.parentCollection, parentKey) {
            case (.none, nil), (.none, .some("")): return true
            case (.key(let k), .some(let pk)): return k == pk
            default: return false
            }
        }

        guard let found = target else { return nil }
        return (key: found.key, version: found.version)
    }

    /// Delete a collection.
    public func deleteCollection(collectionKey: String, version: Int) async throws {
        try await delete(path: "/users/\(userId)/collections/\(collectionKey)", version: version)
    }

    // MARK: - Items

    /// Create a new item with explicit fields.
    public func createItem(_ itemData: [String: Any]) async throws -> (key: String, version: Int) {
        let result = try await post(path: "/users/\(userId)/items", body: [itemData])

        guard let successful = result["successful"] as? [String: Any],
              let first = successful["0"] as? [String: Any],
              let key = first["key"] as? String,
              let version = first["version"] as? Int else {
            if let failed = result["failed"] as? [String: Any],
               let firstFail = failed["0"] as? [String: Any],
               let message = firstFail["message"] as? String {
                throw ZoteroWebAPIError.writeFailed(message)
            }
            throw ZoteroWebAPIError.writeFailed("Unknown error creating item")
        }

        return (key: key, version: version)
    }

    /// Create a journal article item from structured data.
    public func createJournalArticle(
        title: String,
        creators: [ZoteroAPICreator] = [],
        abstractNote: String? = nil,
        publicationTitle: String? = nil,
        date: String? = nil,
        doi: String? = nil,
        url: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        tags: [String] = [],
        collectionKeys: [String] = []
    ) async throws -> (key: String, version: Int) {
        var itemData: [String: Any] = [
            "itemType": "journalArticle",
            "title": title,
        ]

        if !creators.isEmpty {
            itemData["creators"] = creators.map { creator -> [String: Any] in
                var dict: [String: Any] = ["creatorType": creator.creatorType]
                if let firstName = creator.firstName { dict["firstName"] = firstName }
                if let lastName = creator.lastName { dict["lastName"] = lastName }
                if let name = creator.name { dict["name"] = name }
                return dict
            }
        }

        if let v = abstractNote { itemData["abstractNote"] = v }
        if let v = publicationTitle { itemData["publicationTitle"] = v }
        if let v = date { itemData["date"] = v }
        if let v = doi { itemData["DOI"] = v }
        if let v = url { itemData["url"] = v }
        if let v = volume { itemData["volume"] = v }
        if let v = issue { itemData["issue"] = v }
        if let v = pages { itemData["pages"] = v }

        if !tags.isEmpty {
            itemData["tags"] = tags.map { ["tag": $0] }
        }
        if !collectionKeys.isEmpty {
            itemData["collections"] = collectionKeys
        }

        return try await createItem(itemData)
    }

    /// Add an item to one or more collections by updating its collections field.
    /// Requires the item's current version (from local SQLite or a previous API call).
    public func addItemToCollection(itemKey: String, collectionKeys: [String], currentVersion: Int) async throws {
        // PATCH only updates specified fields
        let body: [String: Any] = ["collections": collectionKeys]
        try await patch(path: "/users/\(userId)/items/\(itemKey)", body: body, version: currentVersion)
    }

    /// Update tags on an item.
    public func updateTags(itemKey: String, tags: [String], currentVersion: Int) async throws {
        let body: [String: Any] = ["tags": tags.map { ["tag": $0] }]
        try await patch(path: "/users/\(userId)/items/\(itemKey)", body: body, version: currentVersion)
    }

    /// Update arbitrary fields on an item (PATCH).
    public func patchItem(itemKey: String, fields: [String: Any], version: Int) async throws {
        try await patch(path: "/users/\(userId)/items/\(itemKey)", body: fields, version: version)
    }

    /// Delete an item.
    public func deleteItem(itemKey: String, version: Int) async throws {
        try await delete(path: "/users/\(userId)/items/\(itemKey)", version: version)
    }

    /// Get an item's current version from the API (needed for updates).
    public func getCollectionVersion(collectionKey: String) async throws -> Int {
        let url = URL(string: "\(baseURL)/users/\(userId)/collections/\(collectionKey)")!
        var request = makeRequest(method: "GET", url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ZoteroWebAPIError.networkError("Failed to get collection version")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? Int else {
            throw ZoteroWebAPIError.networkError("Cannot parse collection version")
        }

        return version
    }

    public func getItemVersion(itemKey: String) async throws -> Int {
        let url = URL(string: "\(baseURL)/users/\(userId)/items/\(itemKey)")!
        var request = makeRequest(method: "GET", url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ZoteroWebAPIError.networkError("Failed to get item version")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? Int else {
            throw ZoteroWebAPIError.networkError("Cannot parse item version")
        }

        return version
    }

    // MARK: - My Publications (Web API fallback)

    /// Get items in "My Publications" via Zotero Web API.
    /// Endpoint: GET /users/{userId}/publications/items
    public func getMyPublications(limit: Int = 100) async throws -> [ZoteroAPIItem] {
        var components = URLComponents(string: "\(baseURL)/users/\(userId)/publications/items")!
        components.queryItems = [
            URLQueryItem(name: "itemType", value: "-attachment || note"),
            URLQueryItem(name: "limit", value: String(min(limit, 100))),
            URLQueryItem(name: "sort", value: "dateModified"),
            URLQueryItem(name: "direction", value: "desc"),
        ]

        var request = makeRequest(method: "GET", url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ZoteroWebAPIError.httpError(code, "Failed to fetch publications")
        }

        return try JSONDecoder().decode([ZoteroAPIItem].self, from: data)
    }

    // MARK: - Search (for idempotency)

    /// Search items by DOI via Zotero Web API (for idempotency check).
    public func searchItemByDOI(doi: String) async throws -> (key: String, version: Int)? {
        let cleanDOI = doi
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")

        guard !cleanDOI.isEmpty else { return nil }

        var components = URLComponents(string: "\(baseURL)/users/\(userId)/items")!
        components.queryItems = [
            URLQueryItem(name: "itemType", value: "-attachment || note"),
            URLQueryItem(name: "q", value: cleanDOI),
            URLQueryItem(name: "qmode", value: "everything"),
            URLQueryItem(name: "limit", value: "5"),
        ]

        var request = makeRequest(method: "GET", url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return nil }

        guard let items = try? JSONDecoder().decode([ZoteroAPIItem].self, from: data) else {
            return nil
        }

        // Match by DOI field (the q search is broad, so verify exact match)
        let match = items.first { item in
            guard let itemDOI = item.data.DOI else { return false }
            return itemDOI.lowercased() == cleanDOI.lowercased()
        }

        guard let found = match else { return nil }
        return (key: found.key, version: found.version)
    }

    // MARK: - Convenience: Add by DOI

    /// Look up a DOI via OpenAlex and create the item in Zotero (idempotent).
    /// Returns the created item key and a summary of what was added.
    public func addItemByDOI(
        doi: String,
        collectionKeys: [String] = [],
        tags: [String] = [],
        academicClient: AcademicSearchClient
    ) async throws -> (key: String, summary: String, isDuplicate: Bool) {
        let resolver = DOIResolver(academic: academicClient)
        return try await addItemByDOI(doi: doi, collectionKeys: collectionKeys, tags: tags, resolver: resolver)
    }

    /// Look up a DOI via the universal DOI resolver and create the item in Zotero (idempotent).
    /// Cascading resolution: OpenAlex → doi.org → Airiti.
    /// Returns isDuplicate=true if an item with the same DOI already exists.
    public func addItemByDOI(
        doi: String,
        collectionKeys: [String] = [],
        tags: [String] = [],
        resolver: DOIResolver
    ) async throws -> (key: String, summary: String, isDuplicate: Bool) {
        // Idempotency check: search by DOI in Zotero Web API
        if let existing = try? await searchItemByDOI(doi: doi) {
            return (key: existing.key, summary: "DOI \(doi) already exists [key: \(existing.key)]", isDuplicate: true)
        }

        let metadata = try await resolver.resolve(doi: doi)
        let itemData = metadata.toZoteroItemData(collectionKeys: collectionKeys, tags: tags)
        let result = try await createItem(itemData)

        let authorStr = metadata.creators.prefix(3).map { c in
            if let name = c.name { return name }
            return [c.firstName, c.lastName].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: ", ")
        let etAl = metadata.creators.count > 3 ? " et al." : ""
        let dateStr = metadata.date != nil ? " (\(metadata.date!))" : ""
        let summary = "\(metadata.title) — \(authorStr)\(etAl)\(dateStr) [key: \(result.key)] (via \(metadata.source))"

        return (key: result.key, summary: summary, isDuplicate: false)
    }

    // MARK: - HTTP Helpers

    private func makeRequest(method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        request.setValue(apiKey, forHTTPHeaderField: "Zotero-API-Key")
        return request
    }

    private func post(path: String, body: Any) async throws -> [String: Any] {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = makeRequest(method: "POST", url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Idempotency token
        let writeToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        request.setValue(writeToken, forHTTPHeaderField: "Zotero-Write-Token")

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZoteroWebAPIError.networkError("Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ZoteroWebAPIError.httpError(httpResponse.statusCode, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZoteroWebAPIError.networkError("Cannot parse response")
        }

        return json
    }

    private func patch(path: String, body: [String: Any], version: Int) async throws {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = makeRequest(method: "PATCH", url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(version)", forHTTPHeaderField: "If-Unmodified-Since-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZoteroWebAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 204 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ZoteroWebAPIError.httpError(httpResponse.statusCode, body)
        }
    }

    private func delete(path: String, version: Int) async throws {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = makeRequest(method: "DELETE", url: url)
        request.setValue("\(version)", forHTTPHeaderField: "If-Unmodified-Since-Version")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZoteroWebAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 204 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ZoteroWebAPIError.httpError(httpResponse.statusCode, body)
        }
    }
}

// MARK: - Errors

public enum ZoteroWebAPIError: Error, LocalizedError {
    case missingAPIKey
    case authenticationFailed(String)
    case networkError(String)
    case httpError(Int, String)
    case writeFailed(String)
    case versionConflict

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "ZOTERO_API_KEY environment variable not set. Get your key at https://www.zotero.org/settings/keys/new"
        case .authenticationFailed(let msg):
            return "Zotero authentication failed: \(msg)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .writeFailed(let msg):
            return "Write failed: \(msg)"
        case .versionConflict:
            return "Version conflict — the item was modified by another client. Try again."
        }
    }
}

// MARK: - AnyCodable helper for generic JSON decoding

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if container.decodeNil() { value = NSNull() }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        default: try container.encodeNil()
        }
    }
}
