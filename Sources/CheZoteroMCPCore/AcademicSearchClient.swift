// Sources/CheZoteroMCPCore/AcademicSearchClient.swift
//
// OpenAlex API client for academic paper search.
// Free API, 250M+ works, no API key required.
// https://docs.openalex.org

import Foundation

// MARK: - Data Models

public struct OpenAlexWork: Codable {
    public let id: String                         // "https://openalex.org/W..."
    public let doi: String?
    public let title: String?
    public let display_name: String?
    public let publication_year: Int?
    public let publication_date: String?
    public let type: String?                      // "journal-article", "book-chapter", etc.
    public let cited_by_count: Int?
    public let authorships: [Authorship]?
    public let primary_location: PrimaryLocation?
    public let open_access: OpenAccess?
    public let abstract_inverted_index: [String: [Int]]?
    public let referenced_works: [String]?        // OpenAlex IDs of references
    public let related_works: [String]?

    /// Reconstruct abstract from inverted index.
    public var abstractText: String? {
        guard let index = abstract_inverted_index, !index.isEmpty else { return nil }

        // Flatten: word → [positions] into [(position, word)]
        var pairs: [(Int, String)] = []
        for (word, positions) in index {
            for pos in positions {
                pairs.append((pos, word))
            }
        }
        pairs.sort { $0.0 < $1.0 }
        return pairs.map(\.1).joined(separator: " ")
    }

    /// Extract short OpenAlex ID (e.g. "W1234567890")
    public var openAlexID: String {
        id.replacingOccurrences(of: "https://openalex.org/", with: "")
    }

    /// Clean DOI (without URL prefix)
    public var cleanDOI: String? {
        guard let doi = doi else { return nil }
        return doi
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")
    }

    /// Formatted author list
    public var authorList: [String] {
        authorships?.compactMap { $0.author?.display_name } ?? []
    }
}

public struct Authorship: Codable {
    public let author_position: String?           // "first", "middle", "last"
    public let author: AuthorInfo?
    public let institutions: [Institution]?
}

public struct AuthorInfo: Codable {
    public let id: String?
    public let display_name: String?
    public let orcid: String?
}

public struct Institution: Codable {
    public let id: String?
    public let display_name: String?
    public let country_code: String?
}

public struct PrimaryLocation: Codable {
    public let source: SourceInfo?
    public let pdf_url: String?
    public let landing_page_url: String?
}

public struct SourceInfo: Codable {
    public let id: String?
    public let display_name: String?              // Journal/conference name
    public let issn_l: String?
    public let type: String?                      // "journal", "repository", etc.
}

public struct OpenAccess: Codable {
    public let is_oa: Bool?
    public let oa_status: String?                 // "gold", "green", "hybrid", "closed"
    public let oa_url: String?
}

// API response wrapper
struct OpenAlexResponse: Codable {
    let meta: OpenAlexMeta?
    let results: [OpenAlexWork]
}

struct OpenAlexMeta: Codable {
    let count: Int?
    let per_page: Int?
    let page: Int?
}

// MARK: - AcademicSearchClient

public class AcademicSearchClient {
    private let session: URLSession
    private let baseURL = "https://api.openalex.org"
    // Polite pool: adding mailto gets better rate limits
    private let mailto: String?

    public init(mailto: String? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        self.mailto = mailto
    }

    // MARK: - Search

    /// Search works by keyword query.
    public func search(query: String, limit: Int = 10) async throws -> [OpenAlexWork] {
        guard !query.isEmpty else { return [] }

        var components = URLComponents(string: "\(baseURL)/works")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "per_page", value: String(min(limit, 50))),
            URLQueryItem(name: "sort", value: "relevance_score:desc"),
        ]
        addMailto(&components)

        let response: OpenAlexResponse = try await fetch(url: components.url!)
        return response.results
    }

    // MARK: - Get Work by DOI

    /// Get a single work by DOI.
    public func getWork(doi: String) async throws -> OpenAlexWork? {
        let cleanDOI = doi
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")

        var components = URLComponents(string: "\(baseURL)/works/https://doi.org/\(cleanDOI)")!
        addMailto(&components)

        do {
            let work: OpenAlexWork = try await fetch(url: components.url!)
            return work
        } catch AcademicSearchError.httpError(let code, _) where code == 404 {
            return nil
        }
    }

    // MARK: - Citations (works that cite a given work)

    /// Get works that cite the given OpenAlex work ID.
    public func getCitations(openAlexID: String, limit: Int = 10) async throws -> [OpenAlexWork] {
        let id = normalizeID(openAlexID)

        var components = URLComponents(string: "\(baseURL)/works")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "cites:\(id)"),
            URLQueryItem(name: "per_page", value: String(min(limit, 50))),
            URLQueryItem(name: "sort", value: "cited_by_count:desc"),
        ]
        addMailto(&components)

        let response: OpenAlexResponse = try await fetch(url: components.url!)
        return response.results
    }

    // MARK: - References (works cited by a given work)

    /// Get works referenced by the given OpenAlex work ID.
    public func getReferences(openAlexID: String, limit: Int = 10) async throws -> [OpenAlexWork] {
        let id = normalizeID(openAlexID)

        var components = URLComponents(string: "\(baseURL)/works")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "cited_by:\(id)"),
            URLQueryItem(name: "per_page", value: String(min(limit, 50))),
            URLQueryItem(name: "sort", value: "cited_by_count:desc"),
        ]
        addMailto(&components)

        let response: OpenAlexResponse = try await fetch(url: components.url!)
        return response.results
    }

    // MARK: - Search by Author

    /// Search works by author name.
    public func searchByAuthor(name: String, limit: Int = 10) async throws -> [OpenAlexWork] {
        guard !name.isEmpty else { return [] }

        var components = URLComponents(string: "\(baseURL)/works")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "raw_author_name.search:\(name)"),
            URLQueryItem(name: "per_page", value: String(min(limit, 50))),
            URLQueryItem(name: "sort", value: "cited_by_count:desc"),
        ]
        addMailto(&components)

        let response: OpenAlexResponse = try await fetch(url: components.url!)
        return response.results
    }

    // MARK: - Private Helpers

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("che-zotero-mcp/1.0.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AcademicSearchError.networkError("Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AcademicSearchError.httpError(httpResponse.statusCode, body)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func addMailto(_ components: inout URLComponents) {
        if let mailto = mailto {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "mailto", value: mailto))
            components.queryItems = items
        }
    }

    /// Normalize an OpenAlex ID: accept "W1234", full URL, or bare number.
    private func normalizeID(_ id: String) -> String {
        if id.hasPrefix("https://openalex.org/") {
            return id
        }
        if id.hasPrefix("W") || id.hasPrefix("w") {
            return "https://openalex.org/\(id.uppercased())"
        }
        // Assume bare number
        return "https://openalex.org/W\(id)"
    }
}

// MARK: - Formatting Helpers

extension OpenAlexWork {
    /// One-line summary for list display.
    public func summary(index: Int? = nil) -> String {
        let prefix = index != nil ? "\(index!). " : ""
        let authors = authorList.prefix(3).joined(separator: ", ")
        let authorSuffix = (authorships?.count ?? 0) > 3 ? " et al." : ""
        let year = publication_year != nil ? "(\(publication_year!))" : "(n.d.)"
        let citations = cited_by_count ?? 0
        let oa = open_access?.is_oa == true ? " [OA]" : ""
        let doiStr = cleanDOI != nil ? " doi:\(cleanDOI!)" : ""

        return "\(prefix)\(display_name ?? title ?? "(untitled)") — \(authors)\(authorSuffix) \(year) [cited: \(citations)]\(oa)\(doiStr)"
    }

    /// Multi-line detail format.
    public func detail() -> String {
        var lines: [String] = []
        lines.append("Title: \(display_name ?? title ?? "(untitled)")")

        if !authorList.isEmpty {
            lines.append("Authors: \(authorList.joined(separator: "; "))")
        }

        if let year = publication_year {
            lines.append("Year: \(year)")
        }
        if let date = publication_date {
            lines.append("Date: \(date)")
        }
        if let type = type {
            lines.append("Type: \(type)")
        }
        if let source = primary_location?.source?.display_name {
            lines.append("Source: \(source)")
        }
        if let doi = cleanDOI {
            lines.append("DOI: \(doi)")
        }
        lines.append("OpenAlex ID: \(openAlexID)")

        if let citations = cited_by_count {
            lines.append("Cited by: \(citations)")
        }

        if let oa = open_access {
            let status = oa.oa_status ?? "unknown"
            let isOA = oa.is_oa == true ? "Yes" : "No"
            lines.append("Open Access: \(isOA) (\(status))")
            if let url = oa.oa_url {
                lines.append("OA URL: \(url)")
            }
        }

        if let pdfURL = primary_location?.pdf_url {
            lines.append("PDF: \(pdfURL)")
        }

        // Institutions from first author
        if let institutions = authorships?.first?.institutions, !institutions.isEmpty {
            let instNames = institutions.compactMap(\.display_name)
            if !instNames.isEmpty {
                lines.append("Institution: \(instNames.joined(separator: "; "))")
            }
        }

        if let abstract = abstractText, !abstract.isEmpty {
            lines.append("\nAbstract:\n\(abstract)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Errors

public enum AcademicSearchError: Error, LocalizedError {
    case networkError(String)
    case httpError(Int, String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        }
    }
}
