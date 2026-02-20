// Sources/CheZoteroMCPCore/EmbeddingManager.swift
//
// Manages MLX-based embeddings for semantic search.
// Uses MLXEmbedders (Apple's official Swift package) for local embedding generation.
// In-memory vector index with brute-force cosine similarity via Accelerate.
// Persistence via SQLite (~/.che-zotero-mcp/embeddings.sqlite).

import Foundation
import MLX
import MLXEmbedders
import Accelerate
import SQLite3

/// Manages embedding generation and vector search for Zotero items.
public class EmbeddingManager {

    /// Default model: BAAI/bge-m3 (multilingual, 1024-dim, supports Chinese + English)
    public static let defaultModelID = "BAAI/bge-m3"

    private let configuration: ModelConfiguration
    private var modelContainer: ModelContainer?

    // In-memory index: [itemKey: L2-normalized embedding]
    private var embeddings: [String: [Float]] = [:]

    // Persistence
    private let storagePath: String

    public init(modelID: String = EmbeddingManager.defaultModelID) {
        self.configuration = ModelConfiguration(id: modelID)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.storagePath = "\(home)/.che-zotero-mcp/embeddings.sqlite"

        // Try to load persisted embeddings on init
        loadFromDisk()
    }

    // MARK: - Model Loading

    /// Load the embedding model. Call once before embedding or searching.
    public func loadModel(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws {
        modelContainer = try await MLXEmbedders.loadModelContainer(
            configuration: configuration,
            progressHandler: progressHandler
        )
    }

    // MARK: - Embedding

    /// Generate L2-normalized embedding for a single text.
    public func embed(text: String) async throws -> [Float] {
        guard let container = modelContainer else {
            throw EmbeddingError.modelNotLoaded
        }

        let result: [Float] = await container.perform { model, tokenizer, pooler in
            let encoded = tokenizer.encode(text: text)
            let seqLen = encoded.count

            // Create input tensors: [1, seqLen]
            let tokens = MLXArray(encoded.map { Int32($0) }).reshaped(1, seqLen)
            let mask = MLXArray.ones([1, seqLen])
            let tokenTypeIds = MLXArray.zeros([1, seqLen], type: Int32.self)

            // Forward pass
            let output = model(tokens, positionIds: nil, tokenTypeIds: tokenTypeIds, attentionMask: mask)

            // Pool and L2-normalize
            let pooled = pooler(output, mask: mask, normalize: true)

            // Eval and convert to Swift array
            let flat = pooled.squeezed()
            eval(flat)
            return flat.asArray(Float.self)
        }

        return result
    }

    /// Batch embed multiple texts.
    public func embed(texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in texts {
            let emb = try await embed(text: text)
            results.append(emb)
        }
        return results
    }

    // MARK: - Index Management

    /// Add or update an item's embedding in the index.
    public func addToIndex(itemKey: String, embedding: [Float]) {
        embeddings[itemKey] = embedding
    }

    /// Remove an item from the index.
    public func removeFromIndex(itemKey: String) {
        embeddings.removeValue(forKey: itemKey)
    }

    /// Number of items in the index.
    public var indexCount: Int { embeddings.count }

    // MARK: - Search

    /// Search the index for items most similar to the query.
    /// Returns (itemKey, similarity) pairs sorted by descending similarity.
    public func search(query: String, limit: Int = 10) async throws -> [(itemKey: String, similarity: Float)] {
        guard !embeddings.isEmpty else { return [] }

        let queryEmbedding = try await embed(text: query)

        // Cosine similarity = dot product (vectors are L2-normalized)
        var results: [(itemKey: String, similarity: Float)] = []

        for (key, storedEmbedding) in embeddings {
            let dim = min(queryEmbedding.count, storedEmbedding.count)
            var dot: Float = 0
            vDSP_dotpr(queryEmbedding, 1, storedEmbedding, 1, &dot, vDSP_Length(dim))
            results.append((itemKey: key, similarity: dot))
        }

        results.sort { $0.similarity > $1.similarity }
        return Array(results.prefix(limit))
    }

    // MARK: - Persistence

    /// Save all in-memory embeddings to SQLite on disk.
    public func saveToDisk() {
        let dir = (storagePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open(storagePath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        // Create table
        let createSQL = """
            CREATE TABLE IF NOT EXISTS embeddings (
                item_key TEXT PRIMARY KEY,
                vector BLOB NOT NULL,
                model_id TEXT NOT NULL
            )
            """
        sqlite3_exec(db, createSQL, nil, nil, nil)

        // Use a transaction for bulk insert
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        // Clear existing data (full rebuild)
        sqlite3_exec(db, "DELETE FROM embeddings", nil, nil, nil)

        let insertSQL = "INSERT INTO embeddings (item_key, vector, model_id) VALUES (?1, ?2, ?3)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        let modelID = Self.defaultModelID

        for (key, vector) in embeddings {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            // Convert [Float] to binary blob
            vector.withUnsafeBufferPointer { buffer in
                let byteCount = buffer.count * MemoryLayout<Float>.size
                sqlite3_bind_blob(stmt, 2, buffer.baseAddress, Int32(byteCount), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            sqlite3_bind_text(stmt, 3, modelID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Load embeddings from SQLite on disk into memory.
    @discardableResult
    public func loadFromDisk() -> Int {
        guard FileManager.default.fileExists(atPath: storagePath) else { return 0 }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(storagePath, &db, flags, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        // Only load embeddings from the current model
        let sql = "SELECT item_key, vector FROM embeddings WHERE model_id = ?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        let modelID = Self.defaultModelID
        sqlite3_bind_text(stmt, 1, modelID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var loaded = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let blobPtr = sqlite3_column_blob(stmt, 1)
            let blobSize = Int(sqlite3_column_bytes(stmt, 1))

            guard let ptr = blobPtr, blobSize > 0 else { continue }

            let floatCount = blobSize / MemoryLayout<Float>.size
            var vector = [Float](repeating: 0, count: floatCount)
            memcpy(&vector, ptr, blobSize)

            embeddings[key] = vector
            loaded += 1
        }

        return loaded
    }
}

// MARK: - Error Types

public enum EmbeddingError: Error, LocalizedError {
    case modelNotLoaded

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Embedding model not loaded. Call loadModel() first."
        }
    }
}
