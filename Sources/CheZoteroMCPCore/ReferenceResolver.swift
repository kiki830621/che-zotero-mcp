// Sources/CheZoteroMCPCore/ReferenceResolver.swift
//
// Reverse reference resolver: given partial metadata (title, authors, year, etc.),
// find the DOI by querying CrossRef and OpenAlex.
//
// Returns each reference as resolved (1 high-confidence match),
// ambiguous (2+ candidates), or unresolved (0 matches).

import Foundation

// MARK: - Input / Output Models

public struct ReferenceInput {
    public let title: String?
    public let authors: [String]?
    public let year: Int?
    public let journal: String?
    public let doi: String?
    public let pmid: String?
    public let arxivId: String?
    public let isbn: String?
    public let issn: String?
    public let volume: String?
    public let issue: String?
    public let pages: String?
}

public struct ResolveCandidate: CustomStringConvertible {
    public let doi: String
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let journal: String?
    public let score: Double       // 0.0–1.0 confidence
    public let source: String      // "crossref", "openalex", "direct", "pubmed", "arxiv"

    public var description: String {
        let authorStr = authors.prefix(3).joined(separator: ", ")
        let etAl = authors.count > 3 ? " et al." : ""
        let yearStr = year != nil ? "(\(year!))" : "(n.d.)"
        return "\(title) — \(authorStr)\(etAl) \(yearStr) [doi:\(doi)] (confidence: \(String(format: "%.0f%%", score * 100)), via \(source))"
    }
}

public enum ResolveResult {
    case resolved(ResolveCandidate)
    case ambiguous([ResolveCandidate])
    case unresolved(reason: String)
}

public struct ResolveOutput {
    public let index: Int
    public let inputTitle: String?
    public let result: ResolveResult
}

// MARK: - ReferenceResolver

public class ReferenceResolver {
    private let academic: AcademicSearchClient
    private let session: URLSession

    /// Minimum title similarity to consider a match
    private let matchThreshold: Double = 0.75
    /// Gap between #1 and #2 candidate scores to auto-resolve
    private let ambiguityGap: Double = 0.15

    public init(academic: AcademicSearchClient) {
        self.academic = academic
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Resolve a batch of references. Returns results in the same order as input.
    /// - Parameter cvAuthorName: If set (CV mode), candidates must include this author. Non-matching candidates are filtered out.
    public func resolve(references: [ReferenceInput], cvAuthorName: String? = nil) async -> [ResolveOutput] {
        var outputs: [ResolveOutput] = []

        for (i, ref) in references.enumerated() {
            let result = await resolveOne(ref, cvAuthorName: cvAuthorName)
            outputs.append(ResolveOutput(index: i, inputTitle: ref.title, result: result))
        }

        return outputs
    }

    // MARK: - Single Reference Resolve

    private func resolveOne(_ ref: ReferenceInput, cvAuthorName: String? = nil) async -> ResolveResult {
        // 1. Already has DOI → direct
        if let doi = ref.doi, !doi.isEmpty {
            let cleanDOI = cleanDOI(doi)
            return .resolved(ResolveCandidate(
                doi: cleanDOI, title: ref.title ?? "(provided DOI)",
                authors: ref.authors ?? [], year: ref.year,
                journal: ref.journal, score: 1.0, source: "direct"
            ))
        }

        // 2. Has PMID → PubMed API
        if let pmid = ref.pmid, !pmid.isEmpty {
            if let candidate = await resolveViaPubMed(pmid: pmid, ref: ref) {
                return .resolved(candidate)
            }
        }

        // 3. Has arXiv ID → construct DOI
        if let arxivId = ref.arxivId, !arxivId.isEmpty {
            let cleanId = arxivId
                .replacingOccurrences(of: "arXiv:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let doi = "10.48550/arXiv.\(cleanId)"
            return .resolved(ResolveCandidate(
                doi: doi, title: ref.title ?? "(arXiv:\(cleanId))",
                authors: ref.authors ?? [], year: ref.year,
                journal: ref.journal, score: 0.95, source: "arxiv"
            ))
        }

        // 4. Has ISSN + title → CrossRef filtered search (very precise)
        if let issn = ref.issn, !issn.isEmpty, let title = ref.title, !title.isEmpty {
            let candidates = await searchCrossRefByTitle(
                title: title, authors: ref.authors, issn: issn
            )
            let classified = classifyCandidates(candidates, inputTitle: title, inputAuthors: ref.authors, inputYear: ref.year, cvAuthorName: cvAuthorName)
            if case .unresolved = classified {
                // Fall through to broader search
            } else {
                return classified
            }
        }

        // 5. Has title → CrossRef title search (precise)
        if let title = ref.title, !title.isEmpty {
            let candidates = await searchCrossRefByTitle(
                title: title, authors: ref.authors, issn: nil
            )
            let classified = classifyCandidates(candidates, inputTitle: title, inputAuthors: ref.authors, inputYear: ref.year, cvAuthorName: cvAuthorName)
            if case .unresolved = classified {
                // Fall through to bibliographic search
            } else {
                return classified
            }
        }

        // 6. Has title → CrossRef bibliographic search (broader, combines title+author+year)
        if let title = ref.title, !title.isEmpty {
            let candidates = await searchCrossRefBibliographic(
                title: title, authors: ref.authors, year: ref.year
            )
            let classified = classifyCandidates(candidates, inputTitle: title, inputAuthors: ref.authors, inputYear: ref.year, cvAuthorName: cvAuthorName)
            if case .unresolved = classified {
                // Fall through to OpenAlex
            } else {
                return classified
            }
        }

        // 7. Title only → OpenAlex search (last resort)
        if let title = ref.title, !title.isEmpty {
            let candidates = await searchOpenAlex(title: title, ref: ref)
            let classified = classifyCandidates(candidates, inputTitle: title, inputAuthors: ref.authors, inputYear: ref.year, cvAuthorName: cvAuthorName)
            return classified
        }

        // 8. Nothing to work with
        return .unresolved(reason: "No title, DOI, PMID, or arXiv ID provided")
    }

    // MARK: - CrossRef Search Methods

    /// Search CrossRef using separate query.title and query.author fields (more precise).
    private func searchCrossRefByTitle(
        title: String, authors: [String]?, issn: String?
    ) async -> [ResolveCandidate] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "rows", value: "5"),
            URLQueryItem(name: "query.title", value: title),
        ]
        if let authors = authors, !authors.isEmpty {
            queryItems.append(URLQueryItem(name: "query.author", value: authors.joined(separator: " ")))
        }
        if let issn = issn, !issn.isEmpty {
            queryItems.append(URLQueryItem(name: "filter", value: "issn:\(issn)"))
        }
        return await fetchCrossRef(queryItems: queryItems)
    }

    /// Search CrossRef using query.bibliographic (combines all metadata into one query string).
    /// More forgiving for partial matches but may be less precise.
    private func searchCrossRefBibliographic(
        title: String, authors: [String]?, year: Int?
    ) async -> [ResolveCandidate] {
        var bibliographic = title
        if let authors = authors, !authors.isEmpty {
            bibliographic += " " + authors.joined(separator: " ")
        }
        if let year = year {
            bibliographic += " \(year)"
        }
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "rows", value: "5"),
            URLQueryItem(name: "query.bibliographic", value: bibliographic),
        ]
        return await fetchCrossRef(queryItems: queryItems)
    }

    /// Execute a CrossRef API query and parse results into candidates.
    private func fetchCrossRef(queryItems: [URLQueryItem]) async -> [ResolveCandidate] {
        var components = URLComponents(string: "https://api.crossref.org/works")!
        var items = queryItems
        items.append(URLQueryItem(name: "mailto", value: "che830621@icloud.com"))
        components.queryItems = items

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("che-zotero-mcp/1.15.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            guard let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = wrapper["message"] as? [String: Any],
                  let resultItems = message["items"] as? [[String: Any]] else {
                return []
            }

            return resultItems.compactMap { item -> ResolveCandidate? in
                guard let doi = item["DOI"] as? String else { return nil }
                let itemTitle = (item["title"] as? [String])?.first ?? "(untitled)"
                let containerTitle = (item["container-title"] as? [String])?.first

                var itemAuthors: [String] = []
                if let authors = item["author"] as? [[String: Any]] {
                    for author in authors {
                        let given = author["given"] as? String ?? ""
                        let family = author["family"] as? String ?? ""
                        let name = author["name"] as? String
                        if let name = name {
                            itemAuthors.append(name)
                        } else if !family.isEmpty {
                            itemAuthors.append(given.isEmpty ? family : "\(given) \(family)")
                        }
                    }
                }

                var itemYear: Int?
                for dateKey in ["published", "issued", "created"] {
                    if let dateObj = item[dateKey] as? [String: Any],
                       let dateParts = dateObj["date-parts"] as? [[Any]],
                       let parts = dateParts.first,
                       let yr = parts.first as? Int {
                        itemYear = yr
                        break
                    }
                }

                return ResolveCandidate(
                    doi: doi,
                    title: itemTitle,
                    authors: itemAuthors,
                    year: itemYear,
                    journal: containerTitle,
                    score: 0,  // will be re-scored by classifyCandidates
                    source: "crossref"
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - OpenAlex Search

    private func searchOpenAlex(title: String, ref: ReferenceInput) async -> [ResolveCandidate] {
        do {
            let works = try await academic.search(query: title, limit: 5)
            return works.compactMap { work -> ResolveCandidate? in
                guard let doi = work.cleanDOI, !doi.isEmpty else { return nil }
                return ResolveCandidate(
                    doi: doi,
                    title: work.display_name ?? work.title ?? "(untitled)",
                    authors: work.authorList,
                    year: work.publication_year,
                    journal: work.primary_location?.source?.display_name,
                    score: 0,  // will be re-scored
                    source: "openalex"
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - PubMed PMID → DOI

    private func resolveViaPubMed(pmid: String, ref: ReferenceInput) async -> ResolveCandidate? {
        // NCBI E-utilities: convert PMID to DOI
        let cleanPMID = pmid.replacingOccurrences(of: "PMID:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=\(cleanPMID)&retmode=json") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let article = result[cleanPMID] as? [String: Any] else {
                return nil
            }

            // Extract DOI from articleids
            var doi: String?
            if let articleIds = article["articleids"] as? [[String: Any]] {
                for idObj in articleIds {
                    if (idObj["idtype"] as? String) == "doi",
                       let value = idObj["value"] as? String {
                        doi = value
                        break
                    }
                }
            }

            guard let resolvedDOI = doi, !resolvedDOI.isEmpty else { return nil }

            let title = article["title"] as? String ?? ref.title ?? "(PMID:\(cleanPMID))"
            let source = article["fulljournalname"] as? String ?? article["source"] as? String

            var authors: [String] = []
            if let authorList = article["authors"] as? [[String: Any]] {
                for author in authorList {
                    if let name = author["name"] as? String {
                        authors.append(name)
                    }
                }
            }

            var year: Int?
            if let pubDate = article["pubdate"] as? String {
                let parts = pubDate.split(separator: " ")
                if let first = parts.first, let yr = Int(first) {
                    year = yr
                }
            }

            return ResolveCandidate(
                doi: resolvedDOI, title: title, authors: authors,
                year: year ?? ref.year, journal: source ?? ref.journal,
                score: 0.95, source: "pubmed"
            )
        } catch {
            return nil
        }
    }

    // MARK: - Candidate Classification

    /// Score candidates against input metadata and classify as resolved/ambiguous/unresolved.
    /// - Parameter cvAuthorName: In CV mode, filter out candidates that don't include this author.
    private func classifyCandidates(
        _ candidates: [ResolveCandidate],
        inputTitle: String,
        inputAuthors: [String]?,
        inputYear: Int?,
        cvAuthorName: String? = nil
    ) -> ResolveResult {
        // In CV mode, filter candidates to those containing the CV author
        var filteredCandidates = candidates
        if let cvAuthor = cvAuthorName, !cvAuthor.isEmpty {
            let cvLastName = extractLastName(cvAuthor).lowercased()
            filteredCandidates = candidates.filter { candidate in
                candidate.authors.contains { author in
                    extractLastName(author).lowercased() == cvLastName
                }
            }
        }

        if filteredCandidates.isEmpty {
            if candidates.isEmpty {
                return .unresolved(reason: "No matching publications found in CrossRef or OpenAlex")
            } else if cvAuthorName != nil {
                let bestTitle = candidates.first.map { "\"\($0.title)\"" } ?? ""
                return .unresolved(reason: "Found \(candidates.count) candidate(s) but none include CV author '\(cvAuthorName!)': \(bestTitle)")
            }
            return .unresolved(reason: "No matching publications found in CrossRef or OpenAlex")
        }

        // Re-score each candidate based on metadata similarity
        let scored = filteredCandidates.map { candidate -> ResolveCandidate in
            let titleScore = titleSimilarity(input: inputTitle, candidate: candidate.title)
            let authorScore = authorSimilarity(input: inputAuthors, candidate: candidate.authors)
            let yearScore = yearMatch(input: inputYear, candidate: candidate.year)

            // Weighted combination: title is most important
            let combinedScore = titleScore * 0.6 + authorScore * 0.25 + yearScore * 0.15

            return ResolveCandidate(
                doi: candidate.doi, title: candidate.title,
                authors: candidate.authors, year: candidate.year,
                journal: candidate.journal, score: combinedScore,
                source: candidate.source
            )
        }
        .sorted { $0.score > $1.score }

        // Deduplicate: if multiple candidates have the same title (normalized),
        // keep only the one with the best year match (or earliest DOI).
        let deduped = deduplicateByTitle(scored)

        if deduped.isEmpty {
            return .unresolved(reason: "No matching publications found in CrossRef or OpenAlex")
        }

        let top = deduped[0]

        // Below threshold → unresolved
        if top.score < matchThreshold {
            return .unresolved(reason: "Best match confidence too low (\(String(format: "%.0f%%", top.score * 100))): \"\(top.title)\" [doi:\(top.doi)]")
        }

        // Only one candidate above threshold, or clear winner
        let aboveThreshold = deduped.filter { $0.score >= matchThreshold }
        if aboveThreshold.count == 1 {
            return .resolved(top)
        }

        // Multiple above threshold — check if there's a clear winner
        let second = deduped[1]
        if top.score - second.score >= ambiguityGap {
            return .resolved(top)
        }

        // Ambiguous: multiple similar-scoring candidates with DIFFERENT titles
        return .ambiguous(Array(aboveThreshold.prefix(5)))
    }

    /// Deduplicate candidates that have the same normalized title.
    /// Keeps the one with the highest score for each unique title.
    private func deduplicateByTitle(_ candidates: [ResolveCandidate]) -> [ResolveCandidate] {
        var seen: [Set<String>: ResolveCandidate] = [:]
        var order: [Set<String>] = []

        for candidate in candidates {
            let key = normalizeForComparison(candidate.title)
            if let existing = seen[key] {
                // Keep the one with higher score
                if candidate.score > existing.score {
                    seen[key] = candidate
                }
            } else {
                seen[key] = candidate
                order.append(key)
            }
        }

        return order.compactMap { seen[$0] }
    }

    // MARK: - Similarity Scoring

    /// Compare titles using word-level Jaccard similarity (case-insensitive, punctuation-stripped).
    private func titleSimilarity(input: String, candidate: String) -> Double {
        let inputWords = normalizeForComparison(input)
        let candidateWords = normalizeForComparison(candidate)

        if inputWords.isEmpty && candidateWords.isEmpty { return 1.0 }
        if inputWords.isEmpty || candidateWords.isEmpty { return 0.0 }

        let intersection = inputWords.intersection(candidateWords)
        let union = inputWords.union(candidateWords)

        return Double(intersection.count) / Double(union.count)
    }

    /// Compare author lists. Returns 1.0 if any last names overlap.
    private func authorSimilarity(input: [String]?, candidate: [String]) -> Double {
        guard let input = input, !input.isEmpty else { return 0.5 }  // no input → neutral
        if candidate.isEmpty { return 0.3 }

        let inputLastNames = Set(input.map { extractLastName($0).lowercased() })
        let candidateLastNames = Set(candidate.map { extractLastName($0).lowercased() })

        let overlap = inputLastNames.intersection(candidateLastNames)
        if overlap.isEmpty { return 0.0 }

        // Score based on how many input authors were found
        return Double(overlap.count) / Double(inputLastNames.count)
    }

    /// Year match: exact = 1.0, off by 1 = 0.7, else 0.0.
    private func yearMatch(input: Int?, candidate: Int?) -> Double {
        guard let input = input else { return 0.5 }  // no input → neutral
        guard let candidate = candidate else { return 0.3 }

        let diff = abs(input - candidate)
        if diff == 0 { return 1.0 }
        if diff == 1 { return 0.7 }  // publication year can vary ±1
        return 0.0
    }

    // MARK: - Text Normalization

    private func normalizeForComparison(_ text: String) -> Set<String> {
        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 1 }  // skip single chars and empty
        return Set(cleaned)
    }

    private func extractLastName(_ name: String) -> String {
        let parts = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        // "John Smith" → "Smith", "Smith, John" → "Smith"
        if name.contains(",") {
            return String(parts.first ?? Substring(name))
        }
        return String(parts.last ?? Substring(name))
    }

    private func cleanDOI(_ doi: String) -> String {
        doi.replacingOccurrences(of: "https://doi.org/", with: "")
           .replacingOccurrences(of: "http://doi.org/", with: "")
           .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
