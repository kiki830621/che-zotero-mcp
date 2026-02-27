// Server+Helpers.swift — Formatting and value extraction helpers
import Foundation
import MCP

extension CheZoteroMCPServer {

    func formatItems(_ items: [ZoteroItem], header: String) -> String {
        if items.isEmpty { return "\(header): no results." }

        var lines = ["\(header) (\(items.count)):"]
        for (i, item) in items.enumerated() {
            let creators = item.creators.isEmpty ? "" : " — \(item.creators.joined(separator: ", "))"
            let date = item.date ?? "n.d."
            lines.append("\(i + 1). [\(item.itemType)] \(item.title)\(creators) (\(date)) [key: \(item.key)]")
        }
        return lines.joined(separator: "\n")
    }

    func formatItemDetail(_ item: ZoteroItem) -> String {
        var lines: [String] = []
        lines.append("Title: \(item.title)")
        lines.append("Type: \(item.itemType)")
        lines.append("Key: \(item.key)")
        if !item.creators.isEmpty {
            lines.append("Creators: \(item.creators.joined(separator: "; "))")
        }
        if let date = item.date { lines.append("Date: \(date)") }
        if let pub = item.publicationTitle { lines.append("Publication: \(pub)") }
        if let doi = item.DOI { lines.append("DOI: \(doi)") }
        if let url = item.url { lines.append("URL: \(url)") }
        if !item.tags.isEmpty { lines.append("Tags: \(item.tags.joined(separator: ", "))") }
        if !item.collections.isEmpty { lines.append("Collections: \(item.collections.joined(separator: ", "))") }
        lines.append("Date Added: \(item.dateAdded)")
        if let abstract = item.abstractNote, !abstract.isEmpty {
            lines.append("\nAbstract:\n\(abstract)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Module-level Value Helpers

/// Safely extract Int from a Value that might be .int or .double
func intFromValue(_ value: Value?) -> Int? {
    guard let value = value else { return nil }
    return Int(value, strict: false)
}

/// Extract an array of strings from a Value (handles JSON array of strings).
func extractStringArray(_ value: Value?) -> [String] {
    guard let value = value, case .array(let arr) = value else { return [] }
    return arr.compactMap(\.stringValue)
}
