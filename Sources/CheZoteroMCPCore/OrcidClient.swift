// Sources/CheZoteroMCPCore/OrcidClient.swift
//
// ORCID Public API client.
// Free, no authentication required for reading public data.
// https://pub.orcid.org/v3.0/

import Foundation

// MARK: - Data Models

public struct OrcidWork {
    public let title: String
    public let type: String?
    public let journalTitle: String?
    public let publicationYear: Int?
    public let doi: String?
    public let putCode: Int
    public let visibility: String?
}

// MARK: - OrcidClient

public class OrcidClient {
    private let baseURL = "https://pub.orcid.org/v3.0"
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Fetch all public works for an ORCID ID.
    /// Returns deduplicated works (ORCID groups multiple sources per work).
    public func getPublications(orcidId: String) async throws -> [OrcidWork] {
        let cleanId = normalizeOrcidId(orcidId)
        let url = URL(string: "\(baseURL)/\(cleanId)/works")!

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OrcidError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw OrcidError.notFound("ORCID ID not found: \(cleanId)")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OrcidError.httpError(httpResponse.statusCode, body)
        }

        return try parseWorks(data: data)
    }

    // MARK: - Parsing

    private func parseWorks(data: Data) throws -> [OrcidWork] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["group"] as? [[String: Any]] else {
            throw OrcidError.parseError("Cannot parse ORCID works response")
        }

        var works: [OrcidWork] = []

        for group in groups {
            guard let summaries = group["work-summary"] as? [[String: Any]],
                  let summary = summaries.first else { continue }

            let title = extractNestedString(summary, path: ["title", "title", "value"]) ?? "(untitled)"
            let type = summary["type"] as? String
            let journalTitle = extractNestedString(summary, path: ["journal-title", "value"])
            let putCode = summary["put-code"] as? Int ?? 0
            let visibility = summary["visibility"] as? String

            // Publication year
            var year: Int?
            if let pubDate = summary["publication-date"] as? [String: Any],
               let yearObj = pubDate["year"] as? [String: Any],
               let yearStr = yearObj["value"] as? String {
                year = Int(yearStr)
            }

            // DOI from external IDs
            var doi: String?
            if let extIds = summary["external-ids"] as? [String: Any],
               let idList = extIds["external-id"] as? [[String: Any]] {
                for extId in idList {
                    if let idType = extId["external-id-type"] as? String,
                       idType == "doi",
                       let idValue = extId["external-id-value"] as? String {
                        doi = idValue
                        break
                    }
                }
            }

            works.append(OrcidWork(
                title: title,
                type: type,
                journalTitle: journalTitle,
                publicationYear: year,
                doi: doi,
                putCode: putCode,
                visibility: visibility
            ))
        }

        return works
    }

    // MARK: - Helpers

    /// Normalize ORCID ID: accept URL or bare ID.
    private func normalizeOrcidId(_ input: String) -> String {
        input
            .replacingOccurrences(of: "https://orcid.org/", with: "")
            .replacingOccurrences(of: "http://orcid.org/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract a nested string value from a JSON dictionary.
    private func extractNestedString(_ dict: [String: Any], path: [String]) -> String? {
        var current: Any = dict
        for key in path {
            guard let d = current as? [String: Any], let next = d[key] else { return nil }
            current = next
        }
        return current as? String
    }
}

// MARK: - Errors

public enum OrcidError: Error, LocalizedError {
    case networkError(String)
    case httpError(Int, String)
    case notFound(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return "ORCID network error: \(msg)"
        case .httpError(let code, let body):
            return "ORCID HTTP \(code): \(body.prefix(200))"
        case .notFound(let msg):
            return msg
        case .parseError(let msg):
            return "ORCID parse error: \(msg)"
        }
    }
}
