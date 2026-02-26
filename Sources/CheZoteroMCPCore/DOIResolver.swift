// Sources/CheZoteroMCPCore/DOIResolver.swift
//
// Universal DOI metadata resolver with cascading fallback.
// Supports all major DOI Registration Agencies:
//   1. OpenAlex (250M+ academic works)
//   2. doi.org content negotiation (Crossref, DataCite, mEDRA, JaLC, KISTI)
//   3. data-doi.airiti.com (Taiwan academic publications)
//
// Returns CSL-JSON compatible metadata that can be used to create Zotero items.

import Foundation

// MARK: - Resolved Metadata

/// Normalized metadata from any DOI source, ready for Zotero item creation.
public struct ResolvedDOIMetadata {
    public let title: String
    public let creators: [ZoteroAPICreator]
    public let abstractNote: String?
    public let publicationTitle: String?
    public let date: String?
    public let doi: String
    public let url: String?
    public let volume: String?
    public let issue: String?
    public let pages: String?
    public let itemType: String
    public let source: String  // which resolver succeeded

    /// Convert to Zotero API item data dictionary.
    public func toZoteroItemData(collectionKeys: [String] = [], tags: [String] = []) -> [String: Any] {
        var data: [String: Any] = [
            "itemType": itemType,
            "title": title,
            "DOI": doi,
        ]

        if !creators.isEmpty {
            data["creators"] = creators.map { c -> [String: Any] in
                var d: [String: Any] = ["creatorType": c.creatorType]
                if let fn = c.firstName { d["firstName"] = fn }
                if let ln = c.lastName { d["lastName"] = ln }
                if let n = c.name { d["name"] = n }
                return d
            }
        }

        if let v = abstractNote { data["abstractNote"] = v }
        if let v = publicationTitle { data["publicationTitle"] = v }
        if let v = date { data["date"] = v }
        if let v = url { data["url"] = v }
        if let v = volume { data["volume"] = v }
        if let v = issue { data["issue"] = v }
        if let v = pages { data["pages"] = v }
        if !tags.isEmpty { data["tags"] = tags.map { ["tag": $0] } }
        if !collectionKeys.isEmpty { data["collections"] = collectionKeys }

        return data
    }
}

// MARK: - DOIResolver

public class DOIResolver {
    private let academic: AcademicSearchClient
    private let session: URLSession

    public init(academic: AcademicSearchClient) {
        self.academic = academic
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    /// Resolve a DOI to metadata using cascading fallback.
    /// Order: OpenAlex → doi.org content negotiation → Airiti DOI
    public func resolve(doi: String) async throws -> ResolvedDOIMetadata {
        let cleanDOI = cleanDOI(doi)

        // 1. Try OpenAlex (best metadata for academic papers)
        if let result = try? await resolveViaOpenAlex(doi: cleanDOI) {
            return result
        }

        // 2. Try doi.org content negotiation (Crossref, DataCite, mEDRA, JaLC, KISTI)
        if let result = try? await resolveViaDOIOrg(doi: cleanDOI) {
            return result
        }

        // 3. Try Airiti DOI (Taiwan academic publications)
        if let result = try? await resolveViaAiriti(doi: cleanDOI) {
            return result
        }

        // 4. All resolvers failed
        throw DOIResolverError.notFound("Could not resolve metadata for DOI: \(cleanDOI). Tried OpenAlex, doi.org content negotiation, and Airiti DOI.")
    }

    // MARK: - OpenAlex Resolver

    private func resolveViaOpenAlex(doi: String) async throws -> ResolvedDOIMetadata? {
        guard let work = try await academic.getWork(doi: doi) else { return nil }

        let creators: [ZoteroAPICreator] = (work.authorships ?? []).compactMap { authorship in
            guard let name = authorship.author?.display_name else { return nil }
            let parts = name.split(separator: " ", maxSplits: 1)
            if parts.count >= 2 {
                return ZoteroAPICreator(firstName: String(parts[0]), lastName: String(parts[1]))
            } else {
                return ZoteroAPICreator(firstName: nil, lastName: String(name))
            }
        }

        return ResolvedDOIMetadata(
            title: work.display_name ?? work.title ?? "(untitled)",
            creators: creators,
            abstractNote: work.abstractText,
            publicationTitle: work.primary_location?.source?.display_name,
            date: work.publication_date ?? (work.publication_year != nil ? "\(work.publication_year!)" : nil),
            doi: work.cleanDOI ?? doi,
            url: work.primary_location?.landing_page_url,
            volume: nil,
            issue: nil,
            pages: nil,
            itemType: mapOpenAlexType(work.type),
            source: "OpenAlex"
        )
    }

    // MARK: - doi.org Content Negotiation Resolver

    /// Resolve via doi.org content negotiation (returns CSL-JSON).
    /// Works for: Crossref, DataCite, mEDRA, and any RA that supports content negotiation.
    private func resolveViaDOIOrg(doi: String) async throws -> ResolvedDOIMetadata? {
        let url = URL(string: "https://doi.org/\(doi)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.citationstyles.csl+json", forHTTPHeaderField: "Accept")
        request.setValue("che-zotero-mcp/1.2.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        return try parseCSLJSON(data: data, doi: doi, source: "doi.org")
    }

    // MARK: - Airiti DOI Resolver

    /// Resolve via Airiti's DOI metadata service (Taiwan publications).
    private func resolveViaAiriti(doi: String) async throws -> ResolvedDOIMetadata? {
        let url = URL(string: "http://data-doi.airiti.com/\(doi)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.citationstyles.csl+json", forHTTPHeaderField: "Accept")
        request.setValue("che-zotero-mcp/1.2.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        return try parseCSLJSON(data: data, doi: doi, source: "Airiti")
    }

    // MARK: - CSL-JSON Parser

    /// Parse CSL-JSON format (common response from content negotiation).
    private func parseCSLJSON(data: Data, doi: String, source: String) throws -> ResolvedDOIMetadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let title = (json["title"] as? String)
            ?? (json["title"] as? [String])?.first
            ?? "(untitled)"

        // Parse authors
        var creators: [ZoteroAPICreator] = []
        if let authors = json["author"] as? [[String: Any]] {
            for author in authors {
                let given = author["given"] as? String
                let family = author["family"] as? String
                let literal = author["literal"] as? String

                if let given = given, let family = family {
                    creators.append(ZoteroAPICreator(firstName: given, lastName: family))
                } else if let literal = literal {
                    // Single-field name (common in Chinese publications)
                    creators.append(ZoteroAPICreator(creatorType: "author", firstName: nil, lastName: nil, name: literal))
                } else if let family = family {
                    creators.append(ZoteroAPICreator(firstName: nil, lastName: family))
                }
            }
        }

        // Parse date
        var date: String?
        if let issued = json["issued"] as? [String: Any],
           let dateParts = issued["date-parts"] as? [[Any]],
           let parts = dateParts.first {
            let components = parts.compactMap { part -> String? in
                if let num = part as? Int { return String(num) }
                if let str = part as? String { return str }
                return nil
            }
            date = components.joined(separator: "-")
        }

        // Parse pages
        var pages: String?
        if let pageFirst = json["page-first"] as? String {
            pages = pageFirst
            if let pageLast = json["page"] as? String, pageLast.contains("-") {
                pages = pageLast
            }
        } else if let page = json["page"] as? String {
            pages = page
        }

        let containerTitle = json["container-title"] as? String
            ?? (json["container-title"] as? [String])?.first

        return ResolvedDOIMetadata(
            title: title,
            creators: creators,
            abstractNote: json["abstract"] as? String,
            publicationTitle: containerTitle,
            date: date,
            doi: (json["DOI"] as? String) ?? doi,
            url: json["URL"] as? String,
            volume: json["volume"] as? String,
            issue: json["issue"] as? String,
            pages: pages,
            itemType: mapCSLType(json["type"] as? String),
            source: source
        )
    }

    // MARK: - Helpers

    private func cleanDOI(_ doi: String) -> String {
        doi.replacingOccurrences(of: "https://doi.org/", with: "")
           .replacingOccurrences(of: "http://doi.org/", with: "")
           .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map OpenAlex type to Zotero itemType.
    private func mapOpenAlexType(_ type: String?) -> String {
        switch type {
        case "journal-article", "article": return "journalArticle"
        case "book": return "book"
        case "book-chapter": return "bookSection"
        case "proceedings-article", "conference-paper": return "conferencePaper"
        case "dissertation": return "thesis"
        case "preprint", "posted-content": return "preprint"
        case "report": return "report"
        case "dataset": return "document"
        default: return "journalArticle"
        }
    }

    /// Map CSL type to Zotero itemType.
    private func mapCSLType(_ type: String?) -> String {
        switch type {
        case "article-journal": return "journalArticle"
        case "book": return "book"
        case "chapter": return "bookSection"
        case "paper-conference": return "conferencePaper"
        case "thesis": return "thesis"
        case "report": return "report"
        case "dataset": return "document"
        case "article": return "journalArticle"
        default: return "journalArticle"
        }
    }
}

// MARK: - Errors

public enum DOIResolverError: Error, LocalizedError {
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let msg): return msg
        }
    }
}
