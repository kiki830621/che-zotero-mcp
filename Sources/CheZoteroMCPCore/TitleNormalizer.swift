// TitleNormalizer.swift — Convert Title Case → sentence case with proper noun preservation
import Foundation

public struct TitleNormalizer {

    /// Result of normalizing a single title.
    public struct NormalizationResult {
        public let itemKey: String
        public let originalTitle: String
        public let normalizedTitle: String
        public let changed: Bool
        public let protectedWords: [String]  // Words kept capitalized (proper nouns)
    }

    // Short function words that should be lowercased in sentence case
    // (but kept uppercase at sentence start)
    private static let lowercaseWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet",
        "in", "on", "at", "to", "for", "of", "by", "with", "from",
        "as", "is", "was", "are", "were", "be", "been", "being",
        "has", "have", "had", "do", "does", "did",
        "not", "no", "if", "than", "that", "this", "its",
        "vs", "vs.", "via", "per",
    ]

    /// Normalize a title from Title Case to sentence case, preserving proper nouns.
    ///
    /// Algorithm:
    /// 1. Skip titles already in sentence case (< 40% content words capitalized)
    /// 2. Skip non-English titles
    /// 3. Split into words, keep first word capitalized
    /// 4. For each subsequent word:
    ///    - ALL CAPS → keep (acronym)
    ///    - Known proper noun → keep
    ///    - camelCase/internal caps → keep
    ///    - Everything else → lowercase
    public static func normalize(_ title: String, language: String? = nil) -> NormalizationResult {
        // Skip non-English titles
        if let lang = language?.lowercased(),
           !lang.isEmpty && !lang.hasPrefix("en") {
            return NormalizationResult(
                itemKey: "", originalTitle: title, normalizedTitle: title,
                changed: false, protectedWords: []
            )
        }

        // Skip if already sentence case
        if BiblatexAPAFormatter.detectSentenceCase(title) {
            return NormalizationResult(
                itemKey: "", originalTitle: title, normalizedTitle: title,
                changed: false, protectedWords: []
            )
        }

        let words = title.components(separatedBy: " ")
        guard words.count >= 2 else {
            return NormalizationResult(
                itemKey: "", originalTitle: title, normalizedTitle: title,
                changed: false, protectedWords: []
            )
        }

        var resultWords: [String] = []
        var protectedWords: [String] = []
        var isAfterColon = false

        for (i, word) in words.enumerated() {
            if word.isEmpty {
                resultWords.append(word)
                continue
            }

            // First word: always keep capitalized
            if i == 0 || isAfterColon {
                resultWords.append(word)
                isAfterColon = false
                continue
            }

            // Check for colon (next word should be capitalized)
            if word.hasSuffix(":") || word.hasSuffix("—") {
                resultWords.append(lowercaseIfNeeded(word, &protectedWords))
                isAfterColon = true
                continue
            }

            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)

            // ALL CAPS (2+ letters) → keep (acronym)
            if cleaned.count >= 2 && cleaned == cleaned.uppercased() && cleaned.contains(where: { $0.isLetter }) {
                resultWords.append(word)
                protectedWords.append(cleaned)
                continue
            }

            // camelCase or internal uppercase → keep
            if cleaned.count >= 2 {
                let afterFirst = cleaned.dropFirst()
                if afterFirst.contains(where: { $0.isUppercase }) && cleaned.first?.isLowercase == true {
                    resultWords.append(word)
                    protectedWords.append(cleaned)
                    continue
                }
            }

            // Known proper noun → keep
            if ProperNounList.isProperNoun(cleaned) {
                resultWords.append(word)
                protectedWords.append(cleaned)
                continue
            }

            // Dotted abbreviation (U.S., e.g.) → keep
            if cleaned.contains(".") && cleaned.count <= 6 {
                resultWords.append(word)
                protectedWords.append(cleaned)
                continue
            }

            // Hyphenated word: check each part
            if cleaned.contains("-") {
                let parts = word.components(separatedBy: "-")
                let normalizedParts = parts.map { part -> String in
                    let cleanPart = part.trimmingCharacters(in: .punctuationCharacters)
                    if ProperNounList.isProperNoun(cleanPart) {
                        protectedWords.append(cleanPart)
                        return part
                    }
                    if cleanPart == cleanPart.uppercased() && cleanPart.count >= 2 {
                        protectedWords.append(cleanPart)
                        return part
                    }
                    return part.lowercased()
                }
                resultWords.append(normalizedParts.joined(separator: "-"))
                continue
            }

            // Default: lowercase
            resultWords.append(lowercaseIfNeeded(word, &protectedWords))
        }

        let normalized = resultWords.joined(separator: " ")
        return NormalizationResult(
            itemKey: "",
            originalTitle: title,
            normalizedTitle: normalized,
            changed: normalized != title,
            protectedWords: protectedWords
        )
    }

    private static func lowercaseIfNeeded(_ word: String, _ protectedWords: inout [String]) -> String {
        let cleaned = word.trimmingCharacters(in: .punctuationCharacters)

        // Check proper noun list
        if ProperNounList.isProperNoun(cleaned) {
            protectedWords.append(cleaned)
            return word
        }

        // Preserve leading/trailing punctuation while lowercasing the word
        guard let first = word.first else { return word }
        if first.isUppercase {
            return word.lowercased()
        }
        return word
    }

    /// Batch normalize titles for multiple items.
    public static func normalizeBatch(_ items: [ZoteroItem]) -> [NormalizationResult] {
        items.map { item in
            let result = normalize(item.title, language: item.allFields["language"])
            return NormalizationResult(
                itemKey: item.key,
                originalTitle: result.originalTitle,
                normalizedTitle: result.normalizedTitle,
                changed: result.changed,
                protectedWords: result.protectedWords
            )
        }
    }
}
