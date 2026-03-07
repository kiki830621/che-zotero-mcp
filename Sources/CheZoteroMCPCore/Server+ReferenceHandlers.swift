// Server+ReferenceHandlers.swift — Handle resolve_references tool calls
import Foundation
import MCP

extension CheZoteroMCPServer {

    func handleResolveReferences(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let refsValue = params.arguments?["references"],
              case .array(let refsArray) = refsValue else {
            return CallTool.Result(
                content: [.text("'references' array is required. Each element should have at least a 'title' field.")],
                isError: true
            )
        }

        // Parse input references
        var inputs: [ReferenceInput] = []
        for refValue in refsArray {
            guard case .object(let obj) = refValue else { continue }
            inputs.append(ReferenceInput(
                title: obj["title"]?.stringValue,
                authors: extractStringArray(obj["authors"]),
                year: intFromValue(obj["year"]),
                journal: obj["journal"]?.stringValue,
                doi: obj["doi"]?.stringValue,
                pmid: obj["pmid"]?.stringValue,
                arxivId: obj["arxiv_id"]?.stringValue,
                isbn: obj["isbn"]?.stringValue,
                issn: obj["issn"]?.stringValue,
                volume: obj["volume"]?.stringValue,
                issue: obj["issue"]?.stringValue,
                pages: obj["pages"]?.stringValue
            ))
        }

        if inputs.isEmpty {
            return CallTool.Result(
                content: [.text("No valid references found in input array.")],
                isError: true
            )
        }

        // Resolve
        let resolver = ReferenceResolver(academic: academic)
        let outputs = await resolver.resolve(references: inputs)

        // Format output grouped by status
        var resolved: [(Int, ResolveCandidate)] = []
        var ambiguous: [(Int, String?, [ResolveCandidate])] = []
        var unresolved: [(Int, String?, String)] = []

        for output in outputs {
            switch output.result {
            case .resolved(let candidate):
                resolved.append((output.index + 1, candidate))
            case .ambiguous(let candidates):
                ambiguous.append((output.index + 1, output.inputTitle, candidates))
            case .unresolved(let reason):
                unresolved.append((output.index + 1, output.inputTitle, reason))
            }
        }

        var lines: [String] = []
        lines.append("=== Reference Resolution Results ===")
        lines.append("Total: \(inputs.count) | Resolved: \(resolved.count) | Ambiguous: \(ambiguous.count) | Unresolved: \(unresolved.count)")
        lines.append("")

        // Resolved
        if !resolved.isEmpty {
            lines.append("--- Resolved (\(resolved.count)) ---")
            for (idx, candidate) in resolved {
                lines.append("#\(idx). \(candidate)")
            }
            lines.append("")

            // Provide ready-to-use DOI list
            let dois = resolved.map { $0.1.doi }
            lines.append("Ready to import: use import_publications_to_zotero(source='dois', dois=[\(dois.map { "\"\($0)\"" }.joined(separator: ", "))])")
            lines.append("")
        }

        // Ambiguous
        if !ambiguous.isEmpty {
            lines.append("--- Ambiguous (\(ambiguous.count)) — please select the correct match ---")
            for (idx, inputTitle, candidates) in ambiguous {
                let title = inputTitle ?? "(no title)"
                lines.append("#\(idx). Input: \"\(title)\"")
                for (ci, candidate) in candidates.enumerated() {
                    let letter = String(UnicodeScalar(65 + ci)!)  // A, B, C...
                    lines.append("  \(letter). \(candidate)")
                }
            }
            lines.append("")
            lines.append("To resolve: tell me which option (A/B/C) for each ambiguous reference, and I'll add the DOIs to the import list.")
            lines.append("")
        }

        // Unresolved
        if !unresolved.isEmpty {
            lines.append("--- Unresolved (\(unresolved.count)) ---")
            for (idx, inputTitle, reason) in unresolved {
                let title = inputTitle ?? "(no title)"
                lines.append("#\(idx). \"\(title)\" — \(reason)")
            }
            lines.append("")
            lines.append("These may be conference presentations, unpublished works, or items not indexed in CrossRef/OpenAlex.")
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Import from References (source='references')

    /// Full CV import pipeline: resolve DOIs when possible, create items from raw metadata when not.
    func handleImportFromReferences(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let refsValue = params.arguments?["references"],
              case .array(let refsArray) = refsValue else {
            return CallTool.Result(
                content: [.text("'references' array is required for source 'references'. Each element should have at least a 'title' field.")],
                isError: true
            )
        }

        let collectionKey = params.arguments?["collection_key"]?.stringValue
        let tags = extractStringArray(params.arguments?["tags"])
        let dryRun = params.arguments?["dry_run"]?.boolValue ?? true
        let skipExisting = params.arguments?["skip_existing"]?.boolValue ?? true

        // Parse input references
        var inputs: [ReferenceInput] = []
        for refValue in refsArray {
            guard case .object(let obj) = refValue else { continue }
            inputs.append(ReferenceInput(
                title: obj["title"]?.stringValue,
                authors: extractStringArray(obj["authors"]),
                year: intFromValue(obj["year"]),
                journal: obj["journal"]?.stringValue,
                doi: obj["doi"]?.stringValue,
                pmid: obj["pmid"]?.stringValue,
                arxivId: obj["arxiv_id"]?.stringValue,
                isbn: obj["isbn"]?.stringValue,
                issn: obj["issn"]?.stringValue,
                volume: obj["volume"]?.stringValue,
                issue: obj["issue"]?.stringValue,
                pages: obj["pages"]?.stringValue
            ))
        }

        if inputs.isEmpty {
            return CallTool.Result(
                content: [.text("No valid references found in input array.")],
                isError: true
            )
        }

        // Step 1: Resolve references to DOIs
        let resolver = ReferenceResolver(academic: academic)
        let outputs = await resolver.resolve(references: inputs)

        // Categorize results
        struct ResolvedRef {
            let index: Int
            let doi: String
            let title: String
        }
        struct UnresolvedRef {
            let index: Int
            let input: ReferenceInput
            let reason: String
        }
        struct AmbiguousRef {
            let index: Int
            let input: ReferenceInput
            let candidates: [ResolveCandidate]
        }

        var resolvedRefs: [ResolvedRef] = []
        var unresolvedRefs: [UnresolvedRef] = []
        var ambiguousRefs: [AmbiguousRef] = []

        for (i, output) in outputs.enumerated() {
            switch output.result {
            case .resolved(let candidate):
                resolvedRefs.append(ResolvedRef(index: i, doi: candidate.doi, title: candidate.title))
            case .ambiguous(let candidates):
                ambiguousRefs.append(AmbiguousRef(index: i, input: inputs[i], candidates: candidates))
            case .unresolved(let reason):
                unresolvedRefs.append(UnresolvedRef(index: i, input: inputs[i], reason: reason))
            }
        }

        // Step 2: Check existing DOIs in Zotero
        var existingDOIs = Set<String>()
        if skipExisting {
            for ref in resolvedRefs {
                if let _ = try? reader.searchByDOI(doi: ref.doi) {
                    existingDOIs.insert(ref.doi.lowercased()
                        .replacingOccurrences(of: "https://doi.org/", with: "")
                        .replacingOccurrences(of: "http://doi.org/", with: ""))
                }
            }
            // Also check unresolved items by title
            for ref in unresolvedRefs {
                if let title = ref.input.title {
                    let items = try? reader.search(query: title, limit: 1)
                    if let items = items, !items.isEmpty,
                       items[0].title.lowercased() == title.lowercased() {
                        existingDOIs.insert("title:\(title.lowercased())")
                    }
                }
            }
        }

        let newResolved = resolvedRefs.filter { ref in
            let normalized = ref.doi.lowercased()
                .replacingOccurrences(of: "https://doi.org/", with: "")
                .replacingOccurrences(of: "http://doi.org/", with: "")
            return !existingDOIs.contains(normalized)
        }
        let newUnresolved = unresolvedRefs.filter { ref in
            guard let title = ref.input.title else { return true }
            return !existingDOIs.contains("title:\(title.lowercased())")
        }

        // Step 3: Build report
        var lines: [String] = []
        let sourceDescription = "References (\(inputs.count) items: \(resolvedRefs.count) with DOI, \(unresolvedRefs.count) metadata-only, \(ambiguousRefs.count) ambiguous)"
        lines.append("Source: \(sourceDescription)")

        if skipExisting {
            let existingCount = (resolvedRefs.count - newResolved.count) + (unresolvedRefs.count - newUnresolved.count)
            if existingCount > 0 {
                lines.append("Already in Zotero: \(existingCount) (will skip)")
            }
        }
        lines.append("To import via DOI: \(newResolved.count)")
        lines.append("To import from metadata: \(newUnresolved.count)")
        lines.append("")

        if dryRun {
            lines.insert("=== DRY RUN (preview only) ===", at: 0)

            if !newResolved.isEmpty {
                lines.append("--- Will import via DOI (full metadata) ---")
                for (i, ref) in newResolved.enumerated() {
                    lines.append("  \(i + 1). \(ref.title) [doi:\(ref.doi)]")
                }
                lines.append("")
            }

            if !newUnresolved.isEmpty {
                lines.append("--- Will import from metadata (no DOI found) ---")
                for (i, ref) in newUnresolved.enumerated() {
                    let title = ref.input.title ?? "(no title)"
                    let authors = ref.input.authors?.joined(separator: ", ") ?? ""
                    let year = ref.input.year != nil ? "(\(ref.input.year!))" : "(n.d.)"
                    let journal = ref.input.journal != nil ? " — \(ref.input.journal!)" : ""
                    lines.append("  \(i + 1). \(title) — \(authors) \(year)\(journal)")
                }
                lines.append("")
            }

            if !ambiguousRefs.isEmpty {
                lines.append("--- Ambiguous (need confirmation, will be skipped) ---")
                for ambig in ambiguousRefs {
                    let title = ambig.input.title ?? "(no title)"
                    lines.append("  #\(ambig.index + 1). \"\(title)\"")
                    for (ci, candidate) in ambig.candidates.prefix(3).enumerated() {
                        let letter = String(UnicodeScalar(65 + ci)!)
                        lines.append("    \(letter). \(candidate)")
                    }
                }
                lines.append("  Tip: Resolve ambiguous items first with resolve_references, then re-import.")
                lines.append("")
            }

            if let ck = collectionKey {
                lines.append("Will add to collection: \(ck)")
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
        let collectionKeys = collectionKey != nil ? [collectionKey!] : []

        var importedDOI = 0
        var importedMeta = 0
        var skippedDup = 0
        var failed = 0
        var importResults: [String] = []

        // 4a: Import resolved items via DOI
        for ref in newResolved {
            do {
                let result = try await api.addItemByDOI(
                    doi: ref.doi,
                    collectionKeys: collectionKeys,
                    tags: tags,
                    resolver: doiResolver
                )
                if result.isDuplicate {
                    skippedDup += 1
                    importResults.append("⏭️ [DOI] \(result.summary)")
                } else {
                    importedDOI += 1
                    importResults.append("✅ [DOI] \(result.summary)")
                }
            } catch {
                failed += 1
                importResults.append("❌ [DOI] \(ref.title) — \(error.localizedDescription)")
            }
        }

        // 4b: Import unresolved items from raw metadata
        for ref in newUnresolved {
            let input = ref.input
            guard let title = input.title, !title.isEmpty else {
                failed += 1
                importResults.append("❌ [META] Skipped — no title")
                continue
            }

            // Build creators
            var creators: [ZoteroAPICreator] = []
            if let authors = input.authors {
                for author in authors {
                    let parts = author.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: " ", maxSplits: 1)
                    if parts.count >= 2 {
                        creators.append(ZoteroAPICreator(firstName: String(parts[0]), lastName: String(parts[1])))
                    } else if !author.isEmpty {
                        creators.append(ZoteroAPICreator(firstName: nil, lastName: author))
                    }
                }
            }

            let date = input.year != nil ? "\(input.year!)" : nil

            do {
                let result = try await api.createJournalArticle(
                    title: title,
                    creators: creators,
                    publicationTitle: input.journal,
                    date: date,
                    volume: input.volume,
                    issue: input.issue,
                    pages: input.pages,
                    tags: tags,
                    collectionKeys: collectionKeys
                )
                importedMeta += 1
                let authorStr = input.authors?.prefix(2).joined(separator: ", ") ?? ""
                let yearStr = date ?? "n.d."
                importResults.append("✅ [META] \(title) — \(authorStr) (\(yearStr)) [key: \(result.key)]")
            } catch {
                failed += 1
                importResults.append("❌ [META] \(title) — \(error.localizedDescription)")
            }
        }

        lines.append("--- Import Results ---")
        for r in importResults {
            lines.append(r)
        }
        lines.append("")
        lines.append("Imported via DOI: \(importedDOI), Imported from metadata: \(importedMeta), Failed: \(failed), Skipped: \(skippedDup + (resolvedRefs.count - newResolved.count))")

        if !ambiguousRefs.isEmpty {
            lines.append("Skipped ambiguous: \(ambiguousRefs.count) (use resolve_references to disambiguate first)")
        }

        let totalImported = importedDOI + importedMeta
        if totalImported > 0 {
            lines.append("Note: Zotero desktop will sync on next cycle to reflect changes locally.")
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Import from CV (source='cv')

    /// CV import: like references, but validates all results against the CV author.
    /// Optionally cross-references ORCID to boost resolve accuracy.
    func handleImportFromCV(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        // Require author_name
        guard let authorName = params.arguments?["author_name"]?.stringValue, !authorName.isEmpty else {
            return CallTool.Result(
                content: [.text("'author_name' is required for source 'cv'. This is the name of the person whose CV you are importing.")],
                isError: true
            )
        }

        guard let refsValue = params.arguments?["references"],
              case .array(let refsArray) = refsValue else {
            return CallTool.Result(
                content: [.text("'references' array is required for source 'cv'.")],
                isError: true
            )
        }

        let orcidId = params.arguments?["orcid_id"]?.stringValue
        let collectionKey = params.arguments?["collection_key"]?.stringValue
        let tags = extractStringArray(params.arguments?["tags"])
        let dryRun = params.arguments?["dry_run"]?.boolValue ?? true
        let skipExisting = params.arguments?["skip_existing"]?.boolValue ?? true

        // Parse input references
        var inputs: [ReferenceInput] = []
        for refValue in refsArray {
            guard case .object(let obj) = refValue else { continue }
            inputs.append(ReferenceInput(
                title: obj["title"]?.stringValue,
                authors: extractStringArray(obj["authors"]),
                year: intFromValue(obj["year"]),
                journal: obj["journal"]?.stringValue,
                doi: obj["doi"]?.stringValue,
                pmid: obj["pmid"]?.stringValue,
                arxivId: obj["arxiv_id"]?.stringValue,
                isbn: obj["isbn"]?.stringValue,
                issn: obj["issn"]?.stringValue,
                volume: obj["volume"]?.stringValue,
                issue: obj["issue"]?.stringValue,
                pages: obj["pages"]?.stringValue
            ))
        }

        if inputs.isEmpty {
            return CallTool.Result(
                content: [.text("No valid references found in input array.")],
                isError: true
            )
        }

        // Step 0: If ORCID provided, pre-fetch ORCID publications for cross-referencing
        var orcidDOIs: [String: String] = [:]  // normalized title → DOI
        if let orcidId = orcidId, !orcidId.isEmpty {
            let orcidWorks = try await orcid.getPublications(orcidId: orcidId)
            for work in orcidWorks {
                if let doi = work.doi, !doi.isEmpty {
                    let normalizedTitle = work.title.lowercased()
                        .components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    orcidDOIs[normalizedTitle] = doi
                }
            }
        }

        // Step 1: Try ORCID cross-reference first, then resolve remainder
        let resolver = ReferenceResolver(academic: academic)

        struct ResolvedRef {
            let index: Int
            let doi: String
            let title: String
            let source: String  // "orcid-match", "crossref", etc.
        }
        struct UnresolvedRef {
            let index: Int
            let input: ReferenceInput
            let reason: String
        }
        struct AmbiguousRef {
            let index: Int
            let input: ReferenceInput
            let candidates: [ResolveCandidate]
        }

        var resolvedRefs: [ResolvedRef] = []
        var toResolve: [(Int, ReferenceInput)] = []  // index, ref

        // Check ORCID matches first
        for (i, ref) in inputs.enumerated() {
            // If ref already has DOI, skip ORCID check
            if let doi = ref.doi, !doi.isEmpty {
                resolvedRefs.append(ResolvedRef(index: i, doi: doi, title: ref.title ?? "(DOI provided)", source: "direct"))
                continue
            }

            // Try ORCID title match
            if !orcidDOIs.isEmpty, let title = ref.title {
                let normalizedTitle = title.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                if let doi = orcidDOIs[normalizedTitle] {
                    resolvedRefs.append(ResolvedRef(index: i, doi: doi, title: title, source: "orcid-match"))
                    continue
                }
            }

            toResolve.append((i, ref))
        }

        // Resolve remaining via CrossRef/OpenAlex with CV author validation
        var unresolvedRefs: [UnresolvedRef] = []
        var ambiguousRefs: [AmbiguousRef] = []

        if !toResolve.isEmpty {
            let refsToResolve = toResolve.map { $0.1 }
            let outputs = await resolver.resolve(references: refsToResolve, cvAuthorName: authorName)

            for (j, output) in outputs.enumerated() {
                let originalIndex = toResolve[j].0
                let input = toResolve[j].1
                switch output.result {
                case .resolved(let candidate):
                    resolvedRefs.append(ResolvedRef(index: originalIndex, doi: candidate.doi, title: candidate.title, source: candidate.source))
                case .ambiguous(let candidates):
                    ambiguousRefs.append(AmbiguousRef(index: originalIndex, input: input, candidates: candidates))
                case .unresolved(let reason):
                    unresolvedRefs.append(UnresolvedRef(index: originalIndex, input: input, reason: reason))
                }
            }
        }

        // Sort by original index
        resolvedRefs.sort { $0.index < $1.index }

        // Step 2: Check existing in Zotero
        var existingDOIs = Set<String>()
        if skipExisting {
            for ref in resolvedRefs {
                if let _ = try? reader.searchByDOI(doi: ref.doi) {
                    existingDOIs.insert(ref.doi.lowercased()
                        .replacingOccurrences(of: "https://doi.org/", with: "")
                        .replacingOccurrences(of: "http://doi.org/", with: ""))
                }
            }
            for ref in unresolvedRefs {
                if let title = ref.input.title {
                    let items = try? reader.search(query: title, limit: 1)
                    if let items = items, !items.isEmpty,
                       items[0].title.lowercased() == title.lowercased() {
                        existingDOIs.insert("title:\(title.lowercased())")
                    }
                }
            }
        }

        let newResolved = resolvedRefs.filter { ref in
            let normalized = ref.doi.lowercased()
                .replacingOccurrences(of: "https://doi.org/", with: "")
                .replacingOccurrences(of: "http://doi.org/", with: "")
            return !existingDOIs.contains(normalized)
        }
        let newUnresolved = unresolvedRefs.filter { ref in
            guard let title = ref.input.title else { return true }
            return !existingDOIs.contains("title:\(title.lowercased())")
        }

        // Step 3: Build report
        var lines: [String] = []
        let orcidInfo = orcidId != nil ? ", ORCID cross-ref: \(orcidDOIs.count) publications" : ""
        let sourceDescription = "CV of \(authorName) (\(inputs.count) items: \(resolvedRefs.count) with DOI, \(unresolvedRefs.count) metadata-only, \(ambiguousRefs.count) ambiguous\(orcidInfo))"
        lines.append("Source: \(sourceDescription)")

        // Show ORCID-matched items
        let orcidMatched = resolvedRefs.filter { $0.source == "orcid-match" }
        if !orcidMatched.isEmpty {
            lines.append("ORCID cross-reference matched: \(orcidMatched.count)")
        }

        if skipExisting {
            let existingCount = (resolvedRefs.count - newResolved.count) + (unresolvedRefs.count - newUnresolved.count)
            if existingCount > 0 {
                lines.append("Already in Zotero: \(existingCount) (will skip)")
            }
        }
        lines.append("To import via DOI: \(newResolved.count)")
        lines.append("To import from metadata: \(newUnresolved.count)")
        lines.append("")

        if dryRun {
            lines.insert("=== DRY RUN (CV Import: \(authorName)) ===", at: 0)

            if !newResolved.isEmpty {
                lines.append("--- Will import via DOI ---")
                for (i, ref) in newResolved.enumerated() {
                    let sourceTag = ref.source == "orcid-match" ? " [ORCID]" : ""
                    lines.append("  \(i + 1). \(ref.title) [doi:\(ref.doi)]\(sourceTag)")
                }
                lines.append("")
            }

            if !newUnresolved.isEmpty {
                lines.append("--- Will import from metadata (no DOI, author validated as '\(authorName)') ---")
                for (i, ref) in newUnresolved.enumerated() {
                    let title = ref.input.title ?? "(no title)"
                    let authors = ref.input.authors?.joined(separator: ", ") ?? authorName
                    let year = ref.input.year != nil ? "(\(ref.input.year!))" : "(n.d.)"
                    let journal = ref.input.journal != nil ? " — \(ref.input.journal!)" : ""
                    lines.append("  \(i + 1). \(title) — \(authors) \(year)\(journal)")
                }
                lines.append("")
            }

            if !ambiguousRefs.isEmpty {
                lines.append("--- Ambiguous (need confirmation) ---")
                for ambig in ambiguousRefs {
                    let title = ambig.input.title ?? "(no title)"
                    lines.append("  #\(ambig.index + 1). \"\(title)\"")
                    for (ci, candidate) in ambig.candidates.prefix(3).enumerated() {
                        let letter = String(UnicodeScalar(65 + ci)!)
                        lines.append("    \(letter). \(candidate)")
                    }
                }
                lines.append("")
            }

            if let ck = collectionKey {
                lines.append("Will add to collection: \(ck)")
            }
            if !tags.isEmpty {
                lines.append("Will apply tags: \(tags.joined(separator: ", "))")
            }
            lines.append("\nTo execute, call again with dry_run: false")
            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
        }

        // Step 4: Actually import
        guard webAPI != nil else {
            return CallTool.Result(
                content: [.text("Write operations require ZOTERO_API_KEY environment variable.")],
                isError: true
            )
        }
        let api = webAPI!
        let collectionKeys = collectionKey != nil ? [collectionKey!] : []

        var importedDOI = 0
        var importedMeta = 0
        var skippedDup = 0
        var failed = 0
        var importResults: [String] = []

        for ref in newResolved {
            do {
                let result = try await api.addItemByDOI(
                    doi: ref.doi,
                    collectionKeys: collectionKeys,
                    tags: tags,
                    resolver: doiResolver
                )
                if result.isDuplicate {
                    skippedDup += 1
                    importResults.append("⏭️ [DOI] \(result.summary)")
                } else {
                    importedDOI += 1
                    let sourceTag = ref.source == "orcid-match" ? " [ORCID]" : ""
                    importResults.append("✅ [DOI]\(sourceTag) \(result.summary)")
                }
            } catch {
                failed += 1
                importResults.append("❌ [DOI] \(ref.title) — \(error.localizedDescription)")
            }
        }

        for ref in newUnresolved {
            let input = ref.input
            guard let title = input.title, !title.isEmpty else {
                failed += 1
                importResults.append("❌ [META] Skipped — no title")
                continue
            }

            var creators: [ZoteroAPICreator] = []
            if let authors = input.authors {
                for author in authors {
                    let parts = author.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: " ", maxSplits: 1)
                    if parts.count >= 2 {
                        creators.append(ZoteroAPICreator(firstName: String(parts[0]), lastName: String(parts[1])))
                    } else if !author.isEmpty {
                        creators.append(ZoteroAPICreator(firstName: nil, lastName: author))
                    }
                }
            }

            let date = input.year != nil ? "\(input.year!)" : nil

            do {
                let result = try await api.createJournalArticle(
                    title: title,
                    creators: creators,
                    publicationTitle: input.journal,
                    date: date,
                    volume: input.volume,
                    issue: input.issue,
                    pages: input.pages,
                    tags: tags,
                    collectionKeys: collectionKeys
                )
                importedMeta += 1
                let authorStr = input.authors?.prefix(2).joined(separator: ", ") ?? authorName
                let yearStr = date ?? "n.d."
                importResults.append("✅ [META] \(title) — \(authorStr) (\(yearStr)) [key: \(result.key)]")
            } catch {
                failed += 1
                importResults.append("❌ [META] \(title) — \(error.localizedDescription)")
            }
        }

        lines.append("--- Import Results ---")
        for r in importResults {
            lines.append(r)
        }
        lines.append("")
        lines.append("Imported via DOI: \(importedDOI), Imported from metadata: \(importedMeta), Failed: \(failed), Skipped: \(skippedDup + (resolvedRefs.count - newResolved.count))")

        if !ambiguousRefs.isEmpty {
            lines.append("Skipped ambiguous: \(ambiguousRefs.count) (use resolve_references to disambiguate first)")
        }

        let totalImported = importedDOI + importedMeta
        if totalImported > 0 {
            lines.append("Note: Zotero desktop will sync on next cycle to reflect changes locally.")
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }
}
