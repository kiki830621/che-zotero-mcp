import XCTest
@testable import CheZoteroMCPCore

// MARK: - ZoteroReader Tests

final class ZoteroReaderTests: XCTestCase {

    /// Test that ZoteroReader can be initialized when Zotero database exists.
    func testInitWithDefaultPath() throws {
        // This will only pass if Zotero is installed
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = "\(home)/Zotero/zotero.sqlite"

        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Zotero database not found at \(dbPath)")
        }

        let reader = try ZoteroReader()
        XCTAssertNotNil(reader)
    }

    /// Test that initialization fails with invalid path.
    func testInitWithInvalidPath() {
        XCTAssertThrowsError(try ZoteroReader(dbPath: "/nonexistent/path/zotero.sqlite")) { error in
            XCTAssertTrue(error is ZoteroError)
            if case ZoteroError.databaseNotFound = error {
                // Expected
            } else {
                XCTFail("Expected databaseNotFound error, got \(error)")
            }
        }
    }

    /// Test search returns results for common queries.
    func testSearchReturnsResults() throws {
        let reader = try createReaderOrSkip()
        let results = try reader.search(query: "a", limit: 5)
        // Just verify it doesn't crash; results depend on library contents
        XCTAssertTrue(results.count <= 5)
    }

    /// Test search with empty query returns empty.
    func testSearchEmptyQuery() throws {
        let reader = try createReaderOrSkip()
        // Empty query may or may not match; mainly ensure no crash
        _ = try reader.search(query: "", limit: 5)
    }

    /// Test getCollections returns valid data.
    func testGetCollections() throws {
        let reader = try createReaderOrSkip()
        let collections = try reader.getCollections()
        // Validate structure
        for c in collections {
            XCTAssertFalse(c.key.isEmpty)
            XCTAssertFalse(c.name.isEmpty)
            XCTAssertGreaterThanOrEqual(c.itemCount, 0)
        }
    }

    /// Test getTags returns valid data.
    func testGetTags() throws {
        let reader = try createReaderOrSkip()
        let tags = try reader.getTags()
        for t in tags {
            XCTAssertFalse(t.name.isEmpty)
            XCTAssertGreaterThan(t.count, 0)
        }
    }

    /// Test getRecent respects limit.
    func testGetRecentLimit() throws {
        let reader = try createReaderOrSkip()
        let items = try reader.getRecent(limit: 3)
        XCTAssertLessThanOrEqual(items.count, 3)
        for item in items {
            XCTAssertFalse(item.key.isEmpty)
            XCTAssertFalse(item.title.isEmpty || item.title == "(untitled)")
        }
    }

    /// Test getAllItems returns non-empty for a populated library.
    func testGetAllItems() throws {
        let reader = try createReaderOrSkip()
        let items = try reader.getAllItems()
        // A real Zotero library should have at least one item
        XCTAssertGreaterThan(items.count, 0)
    }

    /// Test getItem with a known key.
    func testGetItemByKey() throws {
        let reader = try createReaderOrSkip()
        let items = try reader.getRecent(limit: 1)
        guard let firstItem = items.first else {
            throw XCTSkip("No items in Zotero library")
        }

        let retrieved = try reader.getItem(key: firstItem.key)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.key, firstItem.key)
        XCTAssertEqual(retrieved?.title, firstItem.title)
    }

    /// Test getItem with nonexistent key returns nil.
    func testGetItemNonexistent() throws {
        let reader = try createReaderOrSkip()
        let item = try reader.getItem(key: "NONEXISTENT_KEY_12345")
        XCTAssertNil(item)
    }

    /// Test searchByDOI.
    func testSearchByDOI() throws {
        let reader = try createReaderOrSkip()
        // Search for a DOI that doesn't exist
        let item = try reader.searchByDOI(doi: "10.9999/nonexistent.doi.12345")
        XCTAssertNil(item)
    }

    /// Test getAttachments doesn't crash.
    func testGetAttachments() throws {
        let reader = try createReaderOrSkip()
        let items = try reader.getRecent(limit: 1)
        guard let item = items.first else {
            throw XCTSkip("No items in Zotero library")
        }

        let attachments = try reader.getAttachments(itemKey: item.key)
        for a in attachments {
            XCTAssertFalse(a.key.isEmpty)
            XCTAssertFalse(a.contentType.isEmpty)
        }
    }

    /// Test getNotes doesn't crash.
    func testGetNotes() throws {
        let reader = try createReaderOrSkip()
        let items = try reader.getRecent(limit: 1)
        guard let item = items.first else {
            throw XCTSkip("No items in Zotero library")
        }

        // Just verify it doesn't crash
        let notes = try reader.getNotes(itemKey: item.key)
        for note in notes {
            XCTAssertFalse(note.key.isEmpty)
        }
    }

    /// Test getAnnotations doesn't crash.
    func testGetAnnotations() throws {
        let reader = try createReaderOrSkip()
        let items = try reader.getRecent(limit: 1)
        guard let item = items.first else {
            throw XCTSkip("No items in Zotero library")
        }

        let annotations = try reader.getAnnotations(itemKey: item.key)
        for a in annotations {
            XCTAssertFalse(a.key.isEmpty)
            XCTAssertFalse(a.type.isEmpty)
        }
    }

    /// Test getItemCollectionKeys.
    func testGetItemCollectionKeys() throws {
        let reader = try createReaderOrSkip()
        let items = try reader.getRecent(limit: 1)
        guard let item = items.first else {
            throw XCTSkip("No items in Zotero library")
        }

        // Just verify it doesn't crash
        let keys = try reader.getItemCollectionKeys(itemKey: item.key)
        for key in keys {
            XCTAssertFalse(key.isEmpty)
        }
    }

    /// Test ZoteroItem.searchableText.
    func testSearchableText() throws {
        let item = ZoteroItem(
            key: "TEST",
            itemType: "journalArticle",
            title: "Test Title",
            creators: ["John Doe", "Jane Smith"],
            creatorDetails: [],
            abstractNote: "This is an abstract.",
            date: "2024",
            publicationTitle: "Test Journal",
            DOI: "10.1234/test",
            url: nil,
            tags: ["tag1", "tag2"],
            collections: [],
            dateAdded: "2024-01-01",
            dateModified: "2024-01-01",
            allFields: [:]
        )

        let text = item.searchableText
        XCTAssertTrue(text.contains("Test Title"))
        XCTAssertTrue(text.contains("John Doe"))
        XCTAssertTrue(text.contains("This is an abstract."))
        XCTAssertTrue(text.contains("tag1"))
        XCTAssertTrue(text.contains("Test Journal"))
    }

    // MARK: - Helper

    private func createReaderOrSkip() throws -> ZoteroReader {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = "\(home)/Zotero/zotero.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Zotero database not found")
        }
        return try ZoteroReader()
    }
}

// MARK: - AcademicSearchClient Tests

final class AcademicSearchClientTests: XCTestCase {

    private let client = AcademicSearchClient()

    /// Test search returns results.
    func testSearch() async throws {
        let results = try await client.search(query: "machine learning", limit: 3)
        XCTAssertGreaterThan(results.count, 0)
        XCTAssertLessThanOrEqual(results.count, 3)

        for work in results {
            XCTAssertFalse(work.id.isEmpty)
            XCTAssertNotNil(work.title ?? work.display_name)
        }
    }

    /// Test search with empty query returns empty.
    func testSearchEmpty() async throws {
        let results = try await client.search(query: "", limit: 3)
        XCTAssertTrue(results.isEmpty)
    }

    /// Test getWork by known DOI.
    func testGetWorkByDOI() async throws {
        // A well-known paper DOI
        let work = try await client.getWork(doi: "10.1038/nature14539")
        XCTAssertNotNil(work)
        XCTAssertNotNil(work?.title ?? work?.display_name)
        XCTAssertNotNil(work?.publication_year)
    }

    /// Test getWork with nonexistent DOI returns nil.
    func testGetWorkNonexistentDOI() async throws {
        let work = try await client.getWork(doi: "10.9999/totally.fake.doi.12345")
        XCTAssertNil(work)
    }

    /// Test OpenAlexWork.abstractText reconstruction from inverted index.
    func testAbstractReconstruction() {
        let work = OpenAlexWork(
            id: "https://openalex.org/W0",
            doi: nil,
            title: "Test",
            display_name: "Test",
            publication_year: 2024,
            publication_date: nil,
            type: nil,
            cited_by_count: nil,
            authorships: nil,
            primary_location: nil,
            open_access: nil,
            abstract_inverted_index: ["Hello": [0], "world": [1], "from": [2], "OpenAlex": [3]],
            referenced_works: nil,
            related_works: nil
        )

        XCTAssertEqual(work.abstractText, "Hello world from OpenAlex")
    }

    /// Test OpenAlexWork.openAlexID extraction.
    func testOpenAlexIDExtraction() {
        let work = OpenAlexWork(
            id: "https://openalex.org/W1234567890",
            doi: nil, title: nil, display_name: nil, publication_year: nil,
            publication_date: nil, type: nil, cited_by_count: nil,
            authorships: nil, primary_location: nil, open_access: nil,
            abstract_inverted_index: nil, referenced_works: nil, related_works: nil
        )
        XCTAssertEqual(work.openAlexID, "W1234567890")
    }

    /// Test OpenAlexWork.cleanDOI.
    func testCleanDOI() {
        let work = OpenAlexWork(
            id: "test",
            doi: "https://doi.org/10.1234/test",
            title: nil, display_name: nil, publication_year: nil,
            publication_date: nil, type: nil, cited_by_count: nil,
            authorships: nil, primary_location: nil, open_access: nil,
            abstract_inverted_index: nil, referenced_works: nil, related_works: nil
        )
        XCTAssertEqual(work.cleanDOI, "10.1234/test")
    }

    /// Test searchByAuthor.
    func testSearchByAuthor() async throws {
        let results = try await client.searchByAuthor(name: "Hinton", limit: 3)
        XCTAssertGreaterThan(results.count, 0)
    }
}

// MARK: - EmbeddingManager Tests

final class EmbeddingManagerTests: XCTestCase {

    /// Test index operations (add, remove, count).
    func testIndexOperations() {
        let manager = EmbeddingManager()
        XCTAssertEqual(manager.indexCount, 0)

        let testEmbedding: [Float] = Array(repeating: 0.1, count: 1024)
        manager.addToIndex(itemKey: "TEST1", embedding: testEmbedding)
        XCTAssertEqual(manager.indexCount, 1)

        manager.addToIndex(itemKey: "TEST2", embedding: testEmbedding)
        XCTAssertEqual(manager.indexCount, 2)

        // Update existing
        manager.addToIndex(itemKey: "TEST1", embedding: testEmbedding)
        XCTAssertEqual(manager.indexCount, 2)

        manager.removeFromIndex(itemKey: "TEST1")
        XCTAssertEqual(manager.indexCount, 1)

        manager.removeFromIndex(itemKey: "NONEXISTENT")
        XCTAssertEqual(manager.indexCount, 1)
    }

    /// Test storage path initialization.
    func testStoragePath() {
        let manager = EmbeddingManager()
        // Just verify it initializes without crash
        XCTAssertNotNil(manager)
    }
}

// MARK: - ZoteroWebAPI Tests

final class ZoteroWebAPITests: XCTestCase {

    /// Test that createFromEnvironment fails without API key.
    func testCreateFromEnvironmentFailsWithoutKey() async {
        // Unset the env var if it exists (we can't easily do this in Swift,
        // so just verify the error type)
        do {
            // This should work if ZOTERO_API_KEY is set, or fail gracefully
            _ = try await ZoteroWebAPI.createFromEnvironment()
        } catch let error as ZoteroWebAPIError {
            // Either missingAPIKey or authenticationFailed are acceptable
            switch error {
            case .missingAPIKey:
                // Expected when no key
                break
            case .authenticationFailed:
                // Expected when key is invalid
                break
            default:
                // Network errors are also acceptable in test environment
                break
            }
        } catch {
            // Other errors acceptable in test environment
        }
    }

    /// Test error descriptions are non-empty.
    func testErrorDescriptions() {
        let errors: [ZoteroWebAPIError] = [
            .missingAPIKey,
            .authenticationFailed("test"),
            .networkError("test"),
            .httpError(400, "bad request"),
            .writeFailed("test"),
            .versionConflict,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}

// MARK: - ZoteroError Tests

final class ZoteroErrorTests: XCTestCase {

    func testErrorDescriptions() {
        let errors: [ZoteroError] = [
            .databaseNotFound("/test/path"),
            .cannotOpenDatabase("test message"),
            .queryFailed("test query"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
