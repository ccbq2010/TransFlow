import Foundation

/// Detects questions in live transcription text using heuristic rules.
///
/// Checks for:
/// - Terminal question marks (?, ？)
/// - Question words (what, how, why, when, where, who, which, 什么, 怎么, 为什么, 哪里, 谁, 如何)
/// - Question particles (吗, 呢, 吧 at end of sentence)
struct QuestionDetector {

    /// English question prefixes (case-insensitive).
    private static let englishPrefixes = [
        "what ", "how ", "why ", "when ", "where ", "who ", "which ",
        "could ", "would ", "should ", "can ", "do ", "does ", "did ",
        "is ", "are ", "was ", "were ", "have ", "has ", "will "
    ]

    /// Chinese question keywords.
    private static let chineseKeywords = [
        "什么", "怎么", "为什么", "如何", "哪里", "哪儿", "谁",
        "哪个", "哪些", "多少", "几", "可否", "能否"
    ]

    /// Chinese terminal particles that indicate a question.
    private static let chineseParticles = ["吗", "呢", "吧"]

    /// Check if the given text contains a question.
    static func containsQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }

        return hasQuestionMark(trimmed)
            || hasEnglishQuestionPrefix(trimmed)
            || hasChineseQuestion(trimmed)
    }

    /// Extract the most recent question from text.
    /// Looks at the last sentence that ends with a question mark or contains question patterns.
    static func extractLatestQuestion(from text: String) -> String? {
        let sentences = splitIntoSentences(text)
        for sentence in sentences.reversed() {
            if containsQuestion(sentence) {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    // MARK: - Heuristic Checks

    private static func hasQuestionMark(_ text: String) -> Bool {
        text.contains("?") || text.contains("？")
    }

    private static func hasEnglishQuestionPrefix(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return englishPrefixes.contains { lowercased.hasPrefix($0) }
    }

    private static func hasChineseQuestion(_ text: String) -> Bool {
        // Check for question keywords
        if chineseKeywords.contains(where: { text.contains($0) }) {
            return true
        }
        // Check for terminal particles (at or near end)
        if let last = text.last {
            return chineseParticles.contains(String(last))
        }
        return false
    }

    /// Split text into sentences by common delimiters.
    private static func splitIntoSentences(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ".!?。！？\n")
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
