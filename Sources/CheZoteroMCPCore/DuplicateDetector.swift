// DuplicateDetector.swift — Find and merge duplicate items in Zotero library
import Foundation

// MARK: - Data Models

public struct DuplicateGroup {
    public let items: [ZoteroItem]
    public let confidence: Confidence
    public let reason: String
    public let recommendedKeep: String  // item key recommended to keep

    public enum Confidence: String, Comparable {
        case high = "HIGH"      // Same DOI
        case medium = "MEDIUM"  // Title similarity + author/year
        case low = "LOW"        // Title similarity only

        public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
            let order: [Confidence] = [.low, .medium, .high]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }
}

public struct MergeResult {
    public let keptKey: String
    public let deletedKeys: [String]
    public let mergedTags: [String]
    public let mergedCollections: [String]
    public let updatedFields: [String]
}

// MARK: - DuplicateDetector

public struct DuplicateDetector {

    // Item type priority for choosing which to keep (higher = better)
    private static let typePriority: [String: Int] = [
        "journalArticle": 100,
        "book": 90,
        "bookSection": 85,
        "conferencePaper": 80,
        "thesis": 75,
        "report": 70,
        "preprint": 60,
        "presentation": 50,
        "manuscript": 40,
        "document": 30,
    ]

    // MARK: - Scan

    /// Scan items for duplicates, returning groups sorted by confidence (HIGH first).
    public static func scan(items: [ZoteroItem]) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        var consumed: Set<String> = []

        // Phase 1: DOI matching (HIGH confidence)
        var doiMap: [String: [ZoteroItem]] = [:]
        for item in items {
            if let doi = item.DOI, !doi.isEmpty {
                let clean = cleanDOI(doi)
                doiMap[clean, default: []].append(item)
            }
        }

        for (doi, doiItems) in doiMap where doiItems.count >= 2 {
            let keys = Set(doiItems.map(\.key))
            consumed.formUnion(keys)
            let primary = choosePrimary(doiItems)
            groups.append(DuplicateGroup(
                items: doiItems,
                confidence: .high,
                reason: "Same DOI: \(doi)",
                recommendedKeep: primary.key
            ))
        }

        // Phase 2: Title similarity + author/year (MEDIUM confidence)
        let remaining = items.filter { !consumed.contains($0.key) }

        for i in 0..<remaining.count {
            guard !consumed.contains(remaining[i].key) else { continue }
            var group = [remaining[i]]

            for j in (i + 1)..<remaining.count {
                guard !consumed.contains(remaining[j].key) else { continue }

                let titleSim = normalizedTitleSimilarity(remaining[i].title, remaining[j].title)
                let authorMatch = hasAuthorOverlap(remaining[i], remaining[j])
                let yearMatch = sameYear(remaining[i], remaining[j])

                if titleSim >= 0.85 && (authorMatch || yearMatch) {
                    group.append(remaining[j])
                    consumed.insert(remaining[j].key)
                }
            }

            if group.count >= 2 {
                consumed.insert(remaining[i].key)
                let primary = choosePrimary(group)
                groups.append(DuplicateGroup(
                    items: group,
                    confidence: .medium,
                    reason: "Similar title + matching author/year (Jaccard >= 0.85)",
                    recommendedKeep: primary.key
                ))
            }
        }

        // Phase 3: Title-only near-identical (LOW confidence, very strict threshold)
        let remaining2 = items.filter { !consumed.contains($0.key) }

        for i in 0..<remaining2.count {
            guard !consumed.contains(remaining2[i].key) else { continue }
            var group = [remaining2[i]]

            for j in (i + 1)..<remaining2.count {
                guard !consumed.contains(remaining2[j].key) else { continue }

                let titleSim = normalizedTitleSimilarity(remaining2[i].title, remaining2[j].title)
                if titleSim >= 0.95 {
                    group.append(remaining2[j])
                    consumed.insert(remaining2[j].key)
                }
            }

            if group.count >= 2 {
                consumed.insert(remaining2[i].key)
                let primary = choosePrimary(group)
                groups.append(DuplicateGroup(
                    items: group,
                    confidence: .low,
                    reason: "Near-identical title (Jaccard >= 0.95, no author/year match)",
                    recommendedKeep: primary.key
                ))
            }
        }

        return groups.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Primary Selection

    /// Choose the best item to keep: prioritize type, then completeness, then recency.
    public static func choosePrimary(_ items: [ZoteroItem]) -> ZoteroItem {
        items.sorted { a, b in
            let priorityA = typePriority[a.itemType] ?? 0
            let priorityB = typePriority[b.itemType] ?? 0
            if priorityA != priorityB { return priorityA > priorityB }

            let scoreA = completenessScore(a)
            let scoreB = completenessScore(b)
            if scoreA != scoreB { return scoreA > scoreB }

            return a.dateModified > b.dateModified
        }.first!
    }

    private static func completenessScore(_ item: ZoteroItem) -> Int {
        var score = 0
        if let doi = item.DOI, !doi.isEmpty { score += 3 }
        if let abs = item.abstractNote, !abs.isEmpty { score += 2 }
        if let pub = item.publicationTitle, !pub.isEmpty { score += 2 }
        if !item.creators.isEmpty { score += 2 }
        if let d = item.date, !d.isEmpty { score += 1 }
        if let v = item.allFields["volume"], !v.isEmpty { score += 1 }
        if let i = item.allFields["issue"], !i.isEmpty { score += 1 }
        if let p = item.allFields["pages"], !p.isEmpty { score += 1 }
        score += min(item.tags.count, 5)
        return score
    }

    // MARK: - Merge Logic

    /// Compute merged tags and collections from primary + secondaries.
    /// Returns fields to update on primary and keys to delete.
    public static func computeMerge(
        primary: ZoteroItem,
        secondaries: [ZoteroItem],
        primaryCollectionKeys: [String],
        secondaryCollectionKeys: [[String]]
    ) -> (mergedTags: [String], mergedCollectionKeys: [String], fieldsToFill: [String: String]) {
        // Union tags
        var allTags = Set(primary.tags)
        for sec in secondaries {
            allTags.formUnion(sec.tags)
        }

        // Union collection keys
        var allCollections = Set(primaryCollectionKeys)
        for keys in secondaryCollectionKeys {
            allCollections.formUnion(keys)
        }

        // Fill missing fields from secondaries
        let fillableFields = ["abstractNote", "DOI", "url", "volume", "issue", "pages",
                              "publicationTitle", "date", "publisher", "place", "ISBN", "ISSN"]
        var fieldsToFill: [String: String] = [:]
        for fieldName in fillableFields {
            let primaryValue = primary.allFields[fieldName] ?? ""
            if primaryValue.isEmpty {
                // Find first secondary that has this field
                for sec in secondaries {
                    if let v = sec.allFields[fieldName], !v.isEmpty {
                        fieldsToFill[fieldName] = v
                        break
                    }
                }
            }
        }

        return (
            mergedTags: Array(allTags).sorted(),
            mergedCollectionKeys: Array(allCollections),
            fieldsToFill: fieldsToFill
        )
    }

    // MARK: - Title Similarity

    static func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Word-level Jaccard similarity between two titles.
    static func normalizedTitleSimilarity(_ a: String, _ b: String) -> Double {
        let normA = normalizeTitle(a)
        let normB = normalizeTitle(b)

        if normA == normB { return 1.0 }
        if normA.isEmpty || normB.isEmpty { return 0.0 }

        let wordsA = Set(normA.components(separatedBy: " "))
        let wordsB = Set(normB.components(separatedBy: " "))
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }

    // MARK: - Author Overlap

    private static func hasAuthorOverlap(_ a: ZoteroItem, _ b: ZoteroItem) -> Bool {
        guard !a.creatorDetails.isEmpty && !b.creatorDetails.isEmpty else { return false }
        let authorsA = Set(a.creatorDetails.map { $0.lastName.lowercased() })
        let authorsB = Set(b.creatorDetails.map { $0.lastName.lowercased() })
        return !authorsA.intersection(authorsB).isEmpty
    }

    // MARK: - Year Match

    private static func sameYear(_ a: ZoteroItem, _ b: ZoteroItem) -> Bool {
        guard let dateA = a.date, let dateB = b.date else { return false }
        let yearA = extractYear(dateA)
        let yearB = extractYear(dateB)
        return yearA != nil && yearA == yearB
    }

    private static func extractYear(_ date: String) -> String? {
        guard let range = date.range(of: "\\d{4}", options: .regularExpression) else { return nil }
        return String(date[range])
    }

    // MARK: - DOI Helpers

    private static func cleanDOI(_ doi: String) -> String {
        doi.lowercased()
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "http://doi.org/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
