// Server+AcademicHandlers.swift — Academic search, ORCID, and publication import handlers
import Foundation
import MCP

extension CheZoteroMCPServer {

    // MARK: - Academic Search

    func handleAcademicSearch(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let query = params.arguments?["query"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let works = try await academic.search(query: query, limit: limit)

        if works.isEmpty {
            return CallTool.Result(content: [.text("No results for '\(query)'")], isError: false)
        }

        var lines = ["Academic search: '\(query)' (\(works.count) results):"]
        for (i, work) in works.enumerated() {
            lines.append(work.summary(index: i + 1))
            lines.append("  OpenAlex: \(work.openAlexID)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    func handleAcademicGetPaper(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let doi = params.arguments?["doi"]?.stringValue ?? ""

        // 1. Try OpenAlex first (richest metadata: citations, OA links, OpenAlex ID)
        if let work = try? await academic.getWork(doi: doi) {
            return CallTool.Result(content: [.text(work.detail() + "\n\n[Source: OpenAlex]")], isError: false)
        }

        // 2. Fallback to DOIResolver cascade (doi.org → Airiti — more authoritative, wider coverage)
        if let resolved = try? await doiResolver.resolve(doi: doi) {
            var lines = [
                "Title: \(resolved.title)",
                "DOI: \(resolved.doi)",
            ]
            if !resolved.creators.isEmpty {
                let authors = resolved.creators.map { c in
                    if let name = c.name { return name }
                    return [c.firstName, c.lastName].compactMap { $0 }.joined(separator: " ")
                }
                lines.append("Authors: \(authors.joined(separator: ", "))")
            }
            if let pub = resolved.publicationTitle { lines.append("Journal: \(pub)") }
            if let date = resolved.date { lines.append("Date: \(date)") }
            if let abs = resolved.abstractNote { lines.append("Abstract: \(abs)") }
            if let vol = resolved.volume { lines.append("Volume: \(vol)") }
            if let iss = resolved.issue { lines.append("Issue: \(iss)") }
            if let pgs = resolved.pages { lines.append("Pages: \(pgs)") }
            if let url = resolved.url { lines.append("URL: \(url)") }
            lines.append("Type: \(resolved.itemType)")
            lines.append("\n[Source: \(resolved.source) — Note: OpenAlex did not have this DOI, so citation count and OA info are unavailable]")
            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
        }

        return CallTool.Result(content: [.text("Paper not found for DOI: \(doi). Tried OpenAlex and doi.org content negotiation.")], isError: false)
    }

    func handleAcademicGetCitations(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let openAlexID = params.arguments?["openalex_id"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let works = try await academic.getCitations(openAlexID: openAlexID, limit: limit)

        if works.isEmpty {
            return CallTool.Result(content: [.text("No citations found for \(openAlexID)")], isError: false)
        }

        var lines = ["Papers citing \(openAlexID) (\(works.count) results):"]
        for (i, work) in works.enumerated() {
            lines.append(work.summary(index: i + 1))
            lines.append("  OpenAlex: \(work.openAlexID)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    func handleAcademicGetReferences(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let openAlexID = params.arguments?["openalex_id"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let works = try await academic.getReferences(openAlexID: openAlexID, limit: limit)

        if works.isEmpty {
            return CallTool.Result(content: [.text("No references found for \(openAlexID)")], isError: false)
        }

        var lines = ["References of \(openAlexID) (\(works.count) results):"]
        for (i, work) in works.enumerated() {
            lines.append(work.summary(index: i + 1))
            lines.append("  OpenAlex: \(work.openAlexID)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    func handleAcademicSearchAuthor(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let name = params.arguments?["name"]?.stringValue ?? ""
        let limit = intFromValue(params.arguments?["limit"]) ?? 10

        let works = try await academic.searchByAuthor(name: name, limit: limit)

        if works.isEmpty {
            return CallTool.Result(content: [.text("No papers found for author '\(name)'")], isError: false)
        }

        var lines = ["Papers by '\(name)' (\(works.count) results):"]
        for (i, work) in works.enumerated() {
            lines.append(work.summary(index: i + 1))
            lines.append("  OpenAlex: \(work.openAlexID)")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - ORCID

    func handleOrcidGetPublications(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let orcidId = params.arguments?["orcid_id"]?.stringValue ?? ""

        let works = try await orcid.getPublications(orcidId: orcidId)

        if works.isEmpty {
            return CallTool.Result(
                content: [.text("No public publications found for ORCID: \(orcidId)\nNote: Only works with 'public' visibility on ORCID are returned.")],
                isError: false
            )
        }

        var lines = ["ORCID publications for \(orcidId) (\(works.count)):"]
        for (i, work) in works.enumerated() {
            let year = work.publicationYear != nil ? "(\(work.publicationYear!))" : "(n.d.)"
            let journal = work.journalTitle != nil ? " — \(work.journalTitle!)" : ""
            let doi = work.doi != nil ? " doi:\(work.doi!)" : " (no DOI)"
            let type = work.type ?? "unknown"
            lines.append("\(i + 1). \(work.title) \(year)\(journal) [\(type)]\(doi)")
        }
        lines.append("\nNote: Only works with 'public' visibility on ORCID are listed. Use import_publications_to_zotero with source='orcid' to import these.")
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Publication Import

    func handleImportPublications(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let source = params.arguments?["source"]?.stringValue ?? ""
        let orcidId = params.arguments?["orcid_id"]?.stringValue
        let doisParam = extractStringArray(params.arguments?["dois"])
        let collectionKey = params.arguments?["collection_key"]?.stringValue
        let tags = extractStringArray(params.arguments?["tags"])
        let dryRun = params.arguments?["dry_run"]?.boolValue ?? true
        let skipExisting = params.arguments?["skip_existing"]?.boolValue ?? true

        // Step 1: Collect DOIs from the chosen source
        var dois: [String] = []
        var sourceDescription: String = ""

        switch source {
        case "orcid":
            guard let orcidId = orcidId, !orcidId.isEmpty else {
                return CallTool.Result(content: [.text("orcid_id is required for source 'orcid'")], isError: true)
            }
            let works = try await orcid.getPublications(orcidId: orcidId)
            dois = works.compactMap(\.doi)
            sourceDescription = "ORCID \(orcidId) (\(works.count) works, \(dois.count) with DOI)"

        case "openalex_orcid":
            guard let orcidId = orcidId, !orcidId.isEmpty else {
                return CallTool.Result(content: [.text("orcid_id is required for source 'openalex_orcid'")], isError: true)
            }
            let works = try await academic.getWorksByOrcid(orcid: orcidId)
            dois = works.compactMap(\.cleanDOI).filter { !$0.isEmpty }
            sourceDescription = "OpenAlex ORCID \(orcidId) (\(works.count) works, \(dois.count) with DOI)\n⚠️  OpenAlex may include false positives from author name disambiguation"

        case "dois":
            guard !doisParam.isEmpty else {
                return CallTool.Result(content: [.text("dois array is required for source 'dois'")], isError: true)
            }
            dois = doisParam
            sourceDescription = "Manual DOI list (\(dois.count) DOIs)"

        default:
            return CallTool.Result(content: [.text("Unknown source: '\(source)'. Use 'orcid', 'openalex_orcid', or 'dois'.")], isError: true)
        }

        if dois.isEmpty {
            return CallTool.Result(content: [.text("No DOIs found from source: \(sourceDescription)")], isError: false)
        }

        // Deduplicate DOIs (some sources may have duplicates, e.g. preprint versions)
        var seen = Set<String>()
        dois = dois.filter { doi in
            let normalized = doi.lowercased()
                .replacingOccurrences(of: "https://doi.org/", with: "")
                .replacingOccurrences(of: "http://doi.org/", with: "")
            return seen.insert(normalized).inserted
        }

        // Step 2: Check which DOIs already exist in Zotero
        var existingDOIs = Set<String>()
        if skipExisting {
            for doi in dois {
                if let _ = try? reader.searchByDOI(doi: doi) {
                    existingDOIs.insert(doi.lowercased()
                        .replacingOccurrences(of: "https://doi.org/", with: "")
                        .replacingOccurrences(of: "http://doi.org/", with: ""))
                }
            }
        }

        let newDOIs = dois.filter { doi in
            let normalized = doi.lowercased()
                .replacingOccurrences(of: "https://doi.org/", with: "")
                .replacingOccurrences(of: "http://doi.org/", with: "")
            return !existingDOIs.contains(normalized)
        }

        // Step 3: Build report
        var lines: [String] = []
        lines.append("Source: \(sourceDescription)")
        lines.append("Total DOIs: \(dois.count)")
        if skipExisting {
            lines.append("Already in Zotero: \(existingDOIs.count) (will skip)")
        }
        lines.append("To import: \(newDOIs.count)")
        lines.append("")

        if dryRun {
            // Dry run: just list what would be imported
            lines.insert("=== DRY RUN (preview only) ===", at: 0)

            if !existingDOIs.isEmpty {
                lines.append("--- Already in Zotero (skipping) ---")
                for doi in dois {
                    let normalized = doi.lowercased()
                        .replacingOccurrences(of: "https://doi.org/", with: "")
                        .replacingOccurrences(of: "http://doi.org/", with: "")
                    if existingDOIs.contains(normalized) {
                        lines.append("  ✓ \(doi)")
                    }
                }
                lines.append("")
            }

            if !newDOIs.isEmpty {
                lines.append("--- Will import ---")
                for (i, doi) in newDOIs.enumerated() {
                    // Try to get metadata preview from OpenAlex
                    if let work = try? await academic.getWork(doi: doi) {
                        let authors = work.authorList.prefix(3).joined(separator: ", ")
                        let etAl = (work.authorList.count > 3) ? " et al." : ""
                        let year = work.publication_year != nil ? "(\(work.publication_year!))" : "(n.d.)"
                        lines.append("  \(i + 1). \(work.display_name ?? work.title ?? "(untitled)") — \(authors)\(etAl) \(year)")
                        lines.append("     DOI: \(doi)")
                    } else {
                        lines.append("  \(i + 1). DOI: \(doi) (metadata not found in OpenAlex)")
                    }
                }
            }

            if let ck = collectionKey {
                lines.append("\nWill add to collection: \(ck)")
            }
            if !tags.isEmpty {
                lines.append("Will apply tags: \(tags.joined(separator: ", "))")
            }
            lines.append("\nTo execute, call again with dry_run: false")
            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
        }

        // Step 4: Actually import (dry_run == false)
        guard webAPI != nil else {
            return CallTool.Result(
                content: [.text("Write operations require ZOTERO_API_KEY environment variable. Get your key at https://www.zotero.org/settings/keys/new")],
                isError: true
            )
        }
        let api = webAPI!

        var imported = 0
        var skippedDup = 0
        var failed = 0
        var results: [(doi: String, status: String)] = []
        let collectionKeys = collectionKey != nil ? [collectionKey!] : []

        for doi in newDOIs {
            do {
                let result = try await api.addItemByDOI(
                    doi: doi,
                    collectionKeys: collectionKeys,
                    tags: tags,
                    resolver: doiResolver
                )
                if result.isDuplicate {
                    skippedDup += 1
                    results.append((doi: doi, status: "⏭️ \(result.summary)"))
                } else {
                    imported += 1
                    results.append((doi: doi, status: "✅ \(result.summary)"))
                }
            } catch {
                failed += 1
                results.append((doi: doi, status: "❌ \(error.localizedDescription)"))
            }
        }

        lines.append("--- Import Results ---")
        for r in results {
            lines.append(r.status)
        }
        lines.append("")
        lines.append("Imported: \(imported), Failed: \(failed), Skipped (local): \(existingDOIs.count), Skipped (API dedup): \(skippedDup)")
        if imported > 0 {
            lines.append("Note: Zotero desktop will sync on next cycle to reflect changes locally.")
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }
}
