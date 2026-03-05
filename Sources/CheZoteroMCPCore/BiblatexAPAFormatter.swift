// BiblatexAPAFormatter.swift — Zotero items → biblatex-apa format (.bib)
// Conforms to: https://ctan.org/pkg/biblatex-apa
import Foundation

public struct BiblatexAPAFormatter {

    // MARK: - Public API

    public static func format(_ item: ZoteroItem) -> String {
        let entryType = mapEntryType(item)
        let citeKey = generateCiteKey(item)
        var fields: [(key: String, value: String)] = []

        addCreatorFields(item, entryType, &fields)
        addTitleFields(item, entryType, &fields)
        addSourceFields(item, entryType, &fields)
        addDateFields(item, entryType, &fields)
        addIdentifierFields(item, entryType, &fields)
        addMetadataFields(item, entryType, &fields)

        return buildEntry(entryType, citeKey, fields)
    }

    public static func formatAll(_ items: [ZoteroItem]) -> String {
        items.map { format($0) }.joined(separator: "\n\n")
    }

    // MARK: - Entry Type Mapping

    static func mapEntryType(_ item: ZoteroItem) -> String {
        switch item.itemType {
        case "journalArticle":
            return "ARTICLE"
        case "book":
            let hasAuthor = item.creatorDetails.contains { $0.creatorType == "author" }
            let hasEditor = item.creatorDetails.contains { $0.creatorType == "editor" }
            if !hasAuthor && hasEditor { return "COLLECTION" }
            return "BOOK"
        case "bookSection":
            return "INCOLLECTION"
        case "thesis":
            let thesisType = (item.allFields["thesisType"] ?? "").lowercased()
            if thesisType.contains("master") { return "MASTERSTHESIS" }
            return "PHDTHESIS"
        case "report":
            return "REPORT"
        case "webpage":
            return "ONLINE"
        case "conferencePaper":
            return "INPROCEEDINGS"
        case "presentation":
            return "UNPUBLISHED"
        case "encyclopediaArticle":
            return "INREFERENCE"
        case "newspaperArticle", "magazineArticle":
            // C3: Online-only (no vol/issue/pages) → @ONLINE; print → @ARTICLE
            let hasVol = !(item.allFields["volume"] ?? "").isEmpty
            let hasIssue = !(item.allFields["issue"] ?? "").isEmpty
            let hasPages = !(item.allFields["pages"] ?? "").isEmpty
            if !hasVol && !hasIssue && !hasPages {
                return "ONLINE"
            }
            return "ARTICLE"
        case "film", "videoRecording":
            return "VIDEO"
        case "audioRecording":
            return "AUDIO"
        case "podcast":
            return "AUDIO"
        case "computerProgram":
            return "SOFTWARE"
        case "dataset":
            return "DATASET"
        case "preprint":
            return "ONLINE"
        case "blogPost":
            return "ONLINE"
        case "dictionaryEntry":
            return "INREFERENCE"
        default:
            return "MISC"
        }
    }

    // MARK: - Creator Fields

    static func addCreatorFields(_ item: ZoteroItem, _ entryType: String, _ fields: inout [(key: String, value: String)]) {
        let authors = item.creatorDetails.filter { $0.creatorType == "author" }
        let editors = item.creatorDetails.filter { $0.creatorType == "editor" }
        let translators = item.creatorDetails.filter { $0.creatorType == "translator" }
        let directors = item.creatorDetails.filter { $0.creatorType == "director" }
        let hosts = item.creatorDetails.filter { $0.creatorType == "host" || $0.creatorType == "podcaster" }

        if !directors.isEmpty {
            fields.append(("AUTHOR", formatBibAuthors(directors)))
            fields.append(("AUTHOR+an:role", directors.enumerated().map { "\($0.offset + 1)=director" }.joined(separator: ";")))
        } else if !hosts.isEmpty && authors.isEmpty {
            fields.append(("AUTHOR", formatBibAuthors(hosts)))
            fields.append(("AUTHOR+an:role", hosts.enumerated().map { "\($0.offset + 1)=host" }.joined(separator: ";")))
        } else if !authors.isEmpty {
            fields.append(("AUTHOR", formatBibAuthors(authors)))
        }

        if !editors.isEmpty {
            fields.append(("EDITOR", formatBibAuthors(editors)))
        }

        if !translators.isEmpty {
            fields.append(("TRANSLATOR", formatBibAuthors(translators)))
        }

        // Parse extra field for creator-related metadata
        if let extra = item.allFields["extra"], !extra.isEmpty {
            let parsed = parseExtraField(extra)

            // H6: AUTHOR+an:username (social media handles)
            if let username = parsed["Username"] ?? parsed["username"] {
                let handle = username.hasPrefix("@") ? username : "@\(username)"
                fields.append(("AUTHOR+an:username", "1=\"\(handle)\""))
            }

            // M4: SHORTAUTHOR (corporate abbreviations like APA, WHO)
            if let shortAuthor = parsed["Short Author"] ?? parsed["shortAuthor"] ?? parsed["SHORTAUTHOR"] {
                fields.append(("SHORTAUTHOR", "{{\(shortAuthor)}}"))
            }
        }
    }

    /// Format authors for biblatex.
    /// C1: Compound surnames (multi-word) → brace-protected.
    /// C2: Corporate/institutional authors → double braces {{}}.
    static func formatBibAuthors(_ creators: [ZoteroCreator]) -> String {
        creators.map { creator in
            if creator.firstName.isEmpty {
                // C2: Corporate/institutional author → double braces
                return "{{\(creator.lastName)}}"
            }
            // C1: Multi-word last names → brace-protect to prevent biber mis-parsing
            if creator.lastName.contains(" ") {
                return "\(creator.firstName) {\(creator.lastName)}"
            }
            return "\(creator.firstName) \(creator.lastName)"
        }.joined(separator: " and ")
    }

    // MARK: - Title Fields

    static func addTitleFields(_ item: ZoteroItem, _ entryType: String, _ fields: inout [(key: String, value: String)]) {
        let (mainTitle, subtitle) = splitTitle(item.title)
        fields.append(("TITLE", protectProperNouns(mainTitle)))
        if let sub = subtitle {
            fields.append(("SUBTITLE", protectProperNouns(sub)))
        }

        if let bookTitle = item.allFields["bookTitle"], !bookTitle.isEmpty {
            let (bookMain, bookSub) = splitTitle(bookTitle)
            fields.append(("BOOKTITLE", protectProperNouns(bookMain)))
            if let bs = bookSub {
                fields.append(("BOOKSUBTITLE", protectProperNouns(bs)))
            }
        }

        if let encTitle = item.allFields["encyclopediaTitle"], !encTitle.isEmpty {
            let (encMain, encSub) = splitTitle(encTitle)
            fields.append(("BOOKTITLE", protectProperNouns(encMain)))
            if let es = encSub {
                fields.append(("BOOKSUBTITLE", protectProperNouns(es)))
            }
        }

        if let shortTitle = item.allFields["shortTitle"], !shortTitle.isEmpty {
            fields.append(("SHORTTITLE", shortTitle))
        }
    }

    /// M6: Split title at ": " into main title and subtitle.
    /// Guards against false positives like "Re: Something".
    static func splitTitle(_ title: String) -> (String, String?) {
        guard title.count > 5 else { return (title, nil) }

        let falsePositivePrefixes = ["Re: ", "re: ", "RE: ", "Fw: ", "FW: ", "Fwd: "]
        for fp in falsePositivePrefixes {
            if title.hasPrefix(fp) { return (title, nil) }
        }

        if let range = title.range(of: ": ",
                                    range: title.index(title.startIndex, offsetBy: 3)..<title.endIndex) {
            let main = String(title[..<range.lowerBound])
            let sub = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !sub.isEmpty && sub.count > 2 {
                return (main, sub)
            }
        }

        if let range = title.range(of: " — ",
                                    range: title.index(title.startIndex, offsetBy: 3)..<title.endIndex) {
            let main = String(title[..<range.lowerBound])
            let sub = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !sub.isEmpty && sub.count > 2 {
                return (main, sub)
            }
        }

        return (title, nil)
    }

    /// H1: Protect proper nouns and acronyms with braces for biblatex.
    /// biblatex-apa lowercases English titles; braced words are preserved.
    ///
    /// Strategy depends on detected title casing:
    /// - **Sentence case** (<40% words capitalized): auto-brace all non-initial
    ///   capitalized words (they're likely proper nouns).
    /// - **Title Case** (≥40% words capitalized): brace only detectable patterns
    ///   (acronyms, abbreviations, camelCase) + known proper nouns from ProperNounList.
    static func protectProperNouns(_ text: String) -> String {
        var result = text

        // 1. Always protect sequences of 2+ uppercase letters (acronyms: ADHD, LGBTQ, USA, NYC)
        let acronymPattern = try! NSRegularExpression(pattern: "\\b([A-Z]{2,})\\b")
        let acronymMatches = acronymPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in acronymMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let acronym = String(result[range])
                result.replaceSubrange(range, with: "{\(acronym)}")
            }
        }

        // 2. Always protect dotted abbreviations (U.S., U.K., Dr., e.g.)
        let dottedPattern = try! NSRegularExpression(pattern: "(?<![{])\\b([A-Z]\\.(?:[A-Za-z]\\.)+)")
        let dottedMatches = dottedPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in dottedMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let dotted = String(result[range])
                result.replaceSubrange(range, with: "{\(dotted)}")
            }
        }

        // 3. Always protect words with internal uppercase (iPhone, macOS, LaTeX, YouTube, GitHub)
        let camelPattern = try! NSRegularExpression(pattern: "(?<![{])\\b([a-z]+[A-Z][a-zA-Z]*)\\b")
        let camelMatches = camelPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in camelMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                let word = String(result[range])
                result.replaceSubrange(range, with: "{\(word)}")
            }
        }

        // 4. Detect title casing and apply appropriate strategy
        let isSentenceCase = detectSentenceCase(text)

        if isSentenceCase {
            // Sentence case: any non-initial capitalized word is likely a proper noun → brace it
            result = protectSentenceCaseCapitals(result)
        } else {
            // Title Case: can only protect known proper nouns from the list
            result = protectKnownProperNouns(result)
        }

        return result
    }

    /// Detect whether a title is in sentence case (vs Title Case).
    /// Heuristic: if <40% of content words start with uppercase → sentence case.
    static func detectSentenceCase(_ text: String) -> Bool {
        let words = text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // Need at least 3 words to make a judgement
        guard words.count >= 3 else { return false }

        // Skip first word (always capitalized) and short function words
        let shortWords: Set<String> = ["a", "an", "the", "and", "or", "but", "in",
                                        "on", "at", "to", "for", "of", "by", "with",
                                        "from", "as", "is", "was", "are", "were",
                                        "not", "nor", "so", "yet", "vs", "vs."]
        let contentWords = words.dropFirst().filter { word in
            let clean = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return clean.count > 1 && !shortWords.contains(clean)
        }

        guard !contentWords.isEmpty else { return false }

        let capitalizedCount = contentWords.filter { word in
            guard let first = word.first else { return false }
            return first.isUppercase
        }.count

        let ratio = Double(capitalizedCount) / Double(contentWords.count)
        return ratio < 0.40
    }

    /// For sentence case titles: brace any word starting with uppercase (after position 0),
    /// since in sentence case those are almost certainly proper nouns.
    /// Skips words already braced.
    static func protectSentenceCaseCapitals(_ text: String) -> String {
        // Match capitalized words that aren't already inside braces
        let pattern = try! NSRegularExpression(pattern: "(?<![{A-Za-z])([A-Z][a-z]+)(?![}])")
        var result = text
        let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))

        // Skip the very first word of the text (always capitalized in any case)
        let firstWordEnd = text.firstIndex(where: { $0 == " " }) ?? text.endIndex
        let firstWordRange = text.startIndex..<firstWordEnd

        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: result) {
                // Skip if this is the first word
                if range.lowerBound < firstWordRange.upperBound { continue }
                let word = String(result[range])
                // Skip if already braced (check character before)
                if range.lowerBound > result.startIndex {
                    let before = result[result.index(before: range.lowerBound)]
                    if before == "{" { continue }
                }
                result.replaceSubrange(range, with: "{\(word)}")
            }
        }

        return result
    }

    /// For Title Case titles: protect words that match the known proper noun list.
    static func protectKnownProperNouns(_ text: String) -> String {
        var result = text
        let words = text.components(separatedBy: .whitespaces)

        for word in words {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            guard !cleaned.isEmpty, cleaned.first?.isUppercase == true else { continue }
            // Skip if already braced
            if word.hasPrefix("{") { continue }

            if ProperNounList.isProperNoun(cleaned) {
                // Replace the first occurrence of this word that isn't already braced
                if let range = result.range(of: cleaned) {
                    // Check not already braced
                    let beforeIdx = range.lowerBound
                    if beforeIdx > result.startIndex {
                        let charBefore = result[result.index(before: beforeIdx)]
                        if charBefore == "{" { continue }
                    }
                    result.replaceSubrange(range, with: "{\(cleaned)}")
                }
            }
        }

        return result
    }

    // MARK: - Source Fields

    static func addSourceFields(_ item: ZoteroItem, _ entryType: String, _ fields: inout [(key: String, value: String)]) {
        switch item.itemType {
        case "journalArticle":
            // H2: Apply protectProperNouns to journal title for acronym protection
            if let journal = item.publicationTitle, !journal.isEmpty {
                fields.append(("JOURNALTITLE", protectProperNouns(journal)))
            }
            if let abbr = item.allFields["journalAbbreviation"], !abbr.isEmpty {
                fields.append(("SHORTJOURNAL", abbr))
            }
            if let vol = item.allFields["volume"], !vol.isEmpty {
                fields.append(("VOLUME", vol))
            }
            if let issue = item.allFields["issue"], !issue.isEmpty {
                fields.append(("NUMBER", issue))
            }
            if let pages = item.allFields["pages"], !pages.isEmpty {
                fields.append(("PAGES", normalizePages(pages)))
            }

        case "newspaperArticle", "magazineArticle":
            if entryType == "ONLINE" {
                // C3: Online-only → EPRINT for container/site name
                if let pub = item.publicationTitle, !pub.isEmpty {
                    fields.append(("EPRINT", pub))
                }
            } else {
                if let journal = item.publicationTitle, !journal.isEmpty {
                    fields.append(("JOURNALTITLE", protectProperNouns(journal)))
                }
                if let vol = item.allFields["volume"], !vol.isEmpty {
                    fields.append(("VOLUME", vol))
                }
                if let issue = item.allFields["issue"], !issue.isEmpty {
                    fields.append(("NUMBER", issue))
                }
                if let pages = item.allFields["pages"], !pages.isEmpty {
                    fields.append(("PAGES", normalizePages(pages)))
                }
            }

        case "book":
            if let pub = item.allFields["publisher"], !pub.isEmpty {
                // H7: If publisher matches corporate author → use "Author"
                let corpAuthor = item.creatorDetails.first(where: { $0.firstName.isEmpty })?.lastName ?? ""
                if !corpAuthor.isEmpty && pub.lowercased() == corpAuthor.lowercased() {
                    fields.append(("PUBLISHER", "Author"))
                } else {
                    fields.append(("PUBLISHER", pub))
                }
            }
            if let edition = item.allFields["edition"], !edition.isEmpty {
                fields.append(("EDITION", normalizeEdition(edition)))
            }
            if let vol = item.allFields["volume"], !vol.isEmpty {
                fields.append(("VOLUME", vol))
            }
            if let series = item.allFields["series"], !series.isEmpty {
                fields.append(("SERIES", series))
            }

        case "bookSection", "encyclopediaArticle", "dictionaryEntry":
            if let pub = item.allFields["publisher"], !pub.isEmpty {
                fields.append(("PUBLISHER", pub))
            }
            if let edition = item.allFields["edition"], !edition.isEmpty {
                fields.append(("EDITION", normalizeEdition(edition)))
            }
            if let vol = item.allFields["volume"], !vol.isEmpty {
                fields.append(("VOLUME", vol))
            }
            if let pages = item.allFields["pages"], !pages.isEmpty {
                fields.append(("PAGES", normalizePages(pages)))
            }

        case "thesis":
            if let uni = item.allFields["university"], !uni.isEmpty {
                fields.append(("INSTITUTION", uni))
            }
            if let thesisType = item.allFields["thesisType"], !thesisType.isEmpty {
                fields.append(("TYPE", thesisType))
            }

        case "report":
            // H7: Institution/Publisher with "Author" convention for self-publishing orgs
            let corpAuthor = item.creatorDetails.first(where: { $0.firstName.isEmpty })?.lastName ?? ""
            if let inst = item.allFields["institution"], !inst.isEmpty {
                if !corpAuthor.isEmpty && inst.lowercased() == corpAuthor.lowercased() {
                    fields.append(("INSTITUTION", "Author"))
                } else {
                    fields.append(("INSTITUTION", inst))
                }
            } else if let pub = item.allFields["publisher"], !pub.isEmpty {
                if !corpAuthor.isEmpty && pub.lowercased() == corpAuthor.lowercased() {
                    fields.append(("PUBLISHER", "Author"))
                } else {
                    fields.append(("PUBLISHER", pub))
                }
            }
            if let reportNum = item.allFields["reportNumber"], !reportNum.isEmpty {
                fields.append(("NUMBER", reportNum))
            }
            if let reportType = item.allFields["reportType"], !reportType.isEmpty {
                fields.append(("TITLEADDON", reportType))
            }
            if let series = item.allFields["seriesTitle"] ?? item.allFields["series"], !series.isEmpty {
                fields.append(("SERIES", series))
            }
            if let pages = item.allFields["pages"], !pages.isEmpty {
                fields.append(("PAGES", normalizePages(pages)))
            }
            // M2: LOCATION for reports (international/government docs)
            if let place = item.allFields["place"], !place.isEmpty {
                fields.append(("LOCATION", place))
            }

        case "conferencePaper":
            if let proc = item.allFields["proceedingsTitle"] ?? item.allFields["conferenceName"], !proc.isEmpty {
                fields.append(("BOOKTITLE", proc))
            }
            if let pub = item.allFields["publisher"], !pub.isEmpty {
                fields.append(("PUBLISHER", pub))
            }
            if let pages = item.allFields["pages"], !pages.isEmpty {
                fields.append(("PAGES", normalizePages(pages)))
            }
            if let place = item.allFields["place"], !place.isEmpty {
                fields.append(("LOCATION", place))
            }

        case "webpage", "blogPost":
            if let site = item.allFields["websiteTitle"], !site.isEmpty {
                fields.append(("EPRINT", site))
            }

        case "presentation":
            if let meeting = item.allFields["meetingName"], !meeting.isEmpty {
                fields.append(("EVENTTITLE", meeting))
            }
            if let place = item.allFields["place"], !place.isEmpty {
                fields.append(("VENUE", place))
            }
            if let presType = item.allFields["presentationType"], !presType.isEmpty {
                fields.append(("TITLEADDON", presType))
            }

        // M3: Audio/Video/Podcast proper field handling
        case "podcast":
            if let series = item.allFields["seriesTitle"] ?? item.publicationTitle, !series.isEmpty {
                fields.append(("TITLEADDON", series))
            }
            if let episodeNum = item.allFields["episodeNumber"] ?? item.allFields["number"], !episodeNum.isEmpty {
                fields.append(("NUMBER", episodeNum))
            }
            if let pub = item.allFields["publisher"], !pub.isEmpty {
                fields.append(("PUBLISHER", pub))
            }

        case "audioRecording":
            if let pub = item.allFields["label"] ?? item.allFields["publisher"], !pub.isEmpty {
                fields.append(("PUBLISHER", pub))
            }
            if let vol = item.allFields["volume"], !vol.isEmpty {
                fields.append(("VOLUME", vol))
            }

        case "film", "videoRecording":
            if let pub = item.allFields["studio"] ?? item.allFields["distributor"] ?? item.allFields["publisher"], !pub.isEmpty {
                fields.append(("PUBLISHER", pub))
            }

        default:
            if let pub = item.allFields["publisher"], !pub.isEmpty {
                fields.append(("PUBLISHER", pub))
            }
            if let pages = item.allFields["pages"], !pages.isEmpty {
                fields.append(("PAGES", normalizePages(pages)))
            }
        }
    }

    // MARK: - Date Fields

    static func addDateFields(_ item: ZoteroItem, _ entryType: String, _ fields: inout [(key: String, value: String)]) {
        if let date = item.date, !date.isEmpty {
            fields.append(("DATE", normalizeDate(date)))
        }
        if let origDate = item.allFields["originalDate"], !origDate.isEmpty {
            fields.append(("ORIGDATE", normalizeDate(origDate)))
        }
        // URLDATE for sources where content may change (wikis, social media, webpages)
        if let accessDate = item.allFields["accessDate"], !accessDate.isEmpty {
            let urlDateTypes: Set<String> = ["webpage", "blogPost", "encyclopediaArticle", "dictionaryEntry"]
            if urlDateTypes.contains(item.itemType) || entryType == "ONLINE" {
                let normalized = normalizeDate(accessDate)
                if !normalized.isEmpty {
                    fields.append(("URLDATE", normalized))
                }
            }
        }
    }

    /// Normalize Zotero date to ISO for biblatex.
    /// Handles: "2019-02-00 2/2019", "2019", "2019-03-15", "Spring 2020",
    /// "2015/" (ongoing), "2020-03-15/2020-03-20" (range)
    static func normalizeDate(_ dateStr: String) -> String {
        let trimmed = dateStr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        // M7: Date ranges with "/" (not URLs)
        if trimmed.contains("/") && !trimmed.hasPrefix("http") {
            let parts = trimmed.components(separatedBy: "/")
            if parts.count == 2 {
                let start = normalizeSingleDate(parts[0])
                let end = parts[1].isEmpty ? "" : normalizeSingleDate(parts[1])
                return "\(start)/\(end)"
            }
        }

        return normalizeSingleDate(trimmed)
    }

    static func normalizeSingleDate(_ dateStr: String) -> String {
        let trimmed = dateStr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        // M8: Season dates ("Spring 2020" → "2020-21")
        let seasonMap: [(String, String)] = [
            ("spring", "-21"), ("summer", "-22"),
            ("fall", "-23"), ("autumn", "-23"), ("winter", "-24")
        ]
        let lower = trimmed.lowercased()
        for (season, code) in seasonMap {
            if lower.contains(season) {
                let yearPattern = try! NSRegularExpression(pattern: "(\\d{4})")
                if let match = yearPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                   let range = Range(match.range(at: 1), in: trimmed) {
                    return "\(trimmed[range])\(code)"
                }
            }
        }

        // Take the first space-separated token (the ISO part)
        let isoCandidate = trimmed.components(separatedBy: " ").first ?? trimmed

        if isoCandidate.contains("-") || (isoCandidate.count == 4 && Int(isoCandidate) != nil) {
            var result = isoCandidate
            while result.hasSuffix("-00") {
                result = String(result.dropLast(3))
            }
            return result
        }

        // Fallback: extract year
        let yearPattern = try! NSRegularExpression(pattern: "(\\d{4})")
        if let match = yearPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range(at: 1), in: trimmed) {
            return String(trimmed[range])
        }

        return trimmed
    }

    // MARK: - Identifier Fields

    static func addIdentifierFields(_ item: ZoteroItem, _ entryType: String, _ fields: inout [(key: String, value: String)]) {
        if let doi = item.DOI, !doi.isEmpty {
            fields.append(("DOI", doi))
        }

        // URL: only if no DOI (APA 7), except for online-primary types
        let onlinePrimaryTypes: Set<String> = ["webpage", "blogPost", "presentation"]
        if let url = item.url, !url.isEmpty {
            if (item.DOI ?? "").isEmpty {
                fields.append(("URL", url))
            } else if onlinePrimaryTypes.contains(item.itemType) || entryType == "ONLINE" {
                fields.append(("URL", url))
            }
        }
    }

    // MARK: - Metadata Fields (H3, H4, H5, M5)

    static func addMetadataFields(_ item: ZoteroItem, _ entryType: String, _ fields: inout [(key: String, value: String)]) {
        if let lang = item.allFields["language"], !lang.isEmpty {
            fields.append(("LANGID", mapLanguageToLangID(lang)))
        }

        // H3: ENTRYSUBTYPE for social media, podcasts, etc.
        addEntrySubtype(item, entryType, &fields)

        // H4: TITLEADDON for media descriptors (broader usage)
        addTitleAddon(item, entryType, &fields)

        // Parse extra field for additional metadata
        if let extra = item.allFields["extra"], !extra.isEmpty {
            let parsed = parseExtraField(extra)

            // H5: ADDENDUM for retracted articles
            if let retracted = parsed["Retracted"] ?? parsed["Retraction Date"] ?? parsed["retracted"] {
                fields.append(("ADDENDUM", "Retracted \(retracted)"))
            }

            // PMID
            if let pmid = parsed["PMID"] {
                fields.append(("NOTE", "PMID: \(pmid)"))
            }

            // M5: PUBSTATE for in-press works
            if let pubstate = parsed["Publication Status"] ?? parsed["pubstate"] ?? parsed["PUBSTATE"] {
                fields.append(("PUBSTATE", pubstate.lowercased()))
            } else if extra.lowercased().contains("in press") {
                fields.append(("PUBSTATE", "inpress"))
            }
        }

        if let numVol = item.allFields["numberOfVolumes"], !numVol.isEmpty {
            fields.append(("VOLUMES", numVol))
        }
    }

    /// H3: Determine ENTRYSUBTYPE from item metadata.
    static func addEntrySubtype(_ item: ZoteroItem, _ entryType: String, _ fields: inout [(key: String, value: String)]) {
        if item.itemType == "webpage" || item.itemType == "blogPost" {
            if let site = item.allFields["websiteTitle"]?.lowercased() {
                let subtypeMap: [(contains: String, subtype: String)] = [
                    ("twitter", "Tweet"), ("x.com", "Tweet"),
                    ("facebook", "Facebook post"),
                    ("instagram", "Instagram photo"),
                    ("tiktok", "TikTok video"),
                    ("linkedin", "LinkedIn post"),
                    ("reddit", "Reddit post"),
                    ("youtube", "Video"),
                    ("wikipedia", "Wikipedia entry"),
                ]
                for (keyword, subtype) in subtypeMap {
                    if site.contains(keyword) {
                        fields.append(("ENTRYSUBTYPE", subtype))
                        return
                    }
                }
            }
        }

        if item.itemType == "podcast" {
            let hasEpisode = !(item.allFields["episodeNumber"] ?? item.allFields["number"] ?? "").isEmpty
            fields.append(("ENTRYSUBTYPE", hasEpisode ? "podcast episode" : "podcast"))
        }
    }

    /// H4: Add TITLEADDON for media descriptors beyond reports/presentations.
    static func addTitleAddon(_ item: ZoteroItem, _ entryType: String, _ fields: inout [(key: String, value: String)]) {
        // Skip if already set (e.g., by addSourceFields for reports/presentations/podcasts)
        if fields.contains(where: { $0.key == "TITLEADDON" }) { return }

        // Check extra field for explicit format/medium
        if let extra = item.allFields["extra"], !extra.isEmpty {
            let parsed = parseExtraField(extra)
            if let format = parsed["Format"] ?? parsed["Medium"] ?? parsed["medium"] {
                fields.append(("TITLEADDON", format))
                return
            }
        }

        // Books: detect e-book, audiobook from extra
        if item.itemType == "book" {
            if let extra = item.allFields["extra"]?.lowercased() {
                if extra.contains("e-book") || extra.contains("ebook") || extra.contains("kindle") {
                    fields.append(("TITLEADDON", "E-book"))
                } else if extra.contains("audiobook") {
                    fields.append(("TITLEADDON", "Audiobook"))
                }
            }
        }
    }

    static func mapLanguageToLangID(_ lang: String) -> String {
        let lower = lang.lowercased()
        if lower.hasPrefix("en") { return "english" }
        if lower.hasPrefix("zh") || lower.contains("chinese") { return "chinese" }
        if lower.hasPrefix("ja") || lower.contains("japanese") { return "japanese" }
        if lower.hasPrefix("ko") || lower.contains("korean") { return "korean" }
        if lower.hasPrefix("fr") || lower.contains("french") { return "french" }
        if lower.hasPrefix("de") || lower.contains("german") { return "german" }
        if lower.hasPrefix("es") || lower.contains("spanish") { return "spanish" }
        if lower.hasPrefix("pt") || lower.contains("portuguese") { return "portuguese" }
        if lower.hasPrefix("it") || lower.contains("italian") { return "italian" }
        return lower
    }

    static func parseExtraField(_ extra: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in extra.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let colonRange = trimmed.range(of: ": ") {
                let key = String(trimmed[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Utility

    /// M1: Normalize edition to numeric value for biblatex.
    /// "2nd edition" → "2", "Second" → "2", "3" → "3"
    static func normalizeEdition(_ edition: String) -> String {
        let trimmed = edition.trimmingCharacters(in: .whitespaces)
        if Int(trimmed) != nil { return trimmed }

        // Extract leading number: "2nd edition" → "2"
        let numPattern = try! NSRegularExpression(pattern: "^(\\d+)")
        if let match = numPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range(at: 1), in: trimmed) {
            return String(trimmed[range])
        }

        // Word to number
        let wordMap: [String: String] = [
            "first": "1", "second": "2", "third": "3", "fourth": "4",
            "fifth": "5", "sixth": "6", "seventh": "7", "eighth": "8",
            "ninth": "9", "tenth": "10", "eleventh": "11", "twelfth": "12"
        ]
        let lower = trimmed.lowercased()
        for (word, num) in wordMap {
            if lower.hasPrefix(word) { return num }
        }

        return trimmed
    }

    /// Convert page ranges: single hyphen → double hyphen (biblatex en-dash).
    static func normalizePages(_ pages: String) -> String {
        var result = pages
        result = result.replacingOccurrences(of: "–", with: "-")  // en-dash
        result = result.replacingOccurrences(of: "—", with: "-")  // em-dash
        result = result.replacingOccurrences(of: "--", with: "-")  // already doubled
        result = result.replacingOccurrences(of: "-", with: "--")  // single → double
        return result
    }

    static func generateCiteKey(_ item: ZoteroItem) -> String {
        if let ck = item.allFields["citationKey"], !ck.isEmpty {
            return ck
        }

        if let extra = item.allFields["extra"], !extra.isEmpty {
            let extraFields = parseExtraField(extra)
            if let ck = extraFields["Citation Key"], !ck.isEmpty { return ck }
        }

        let lastName: String
        if let firstCreator = item.creatorDetails.first {
            lastName = firstCreator.lastName
                .components(separatedBy: " ").last ?? firstCreator.lastName
        } else {
            lastName = "unknown"
        }

        let year = normalizeSingleDate(item.date ?? "").prefix(4)
        let cleanName = lastName.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .filter { $0.isLetter }

        return "\(cleanName)\(year)"
    }

    static func buildEntry(_ entryType: String, _ citeKey: String, _ fields: [(key: String, value: String)]) -> String {
        var lines: [String] = []
        lines.append("@\(entryType){\(citeKey),")
        for (i, field) in fields.enumerated() {
            let comma = i < fields.count - 1 ? "," : ""
            let padding = String(repeating: " ", count: max(1, 17 - field.key.count))
            lines.append("  \(field.key)\(padding)= {\(field.value)}\(comma)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}
