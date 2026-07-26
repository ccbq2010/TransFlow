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
        if chineseKeywords.contains(where: { text.contains($0) }) {
            return true
        }
        if let last = text.last {
            return chineseParticles.contains(String(last))
        }
        return false
    }

    /// Split text into sentences, preserving trailing punctuation.
    private static func splitIntoSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if ".!?。！？\n".contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = ""
            }
        }
        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            result.append(remaining)
        }
        return result
    }
}
