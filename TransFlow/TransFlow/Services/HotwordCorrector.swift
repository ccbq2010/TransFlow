import Foundation

/// Post-processes transcription text by replacing misrecognized words/phrases
/// with the correct forms specified in the hotword list.
///
/// - Chinese: simple substring replacement (no tokenization needed).
/// - English: word-boundary regex replacement to avoid partial matches.
struct HotwordCorrector: Sendable {
    /// Each entry: (standardForm, [variantForms...])
    /// All forms are lowercased and trimmed for matching.
    let hotwords: [(standard: String, variants: [String])]

    init(hotwords: [String]) {
        // Parse: each line is "standard" or "standard,variant1,variant2"
        var entries: [(String, [String])] = []
        for line in hotwords {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let standard = parts.first, !standard.isEmpty else { continue }
            let variants = parts.dropFirst().map { $0.lowercased() }
            // 保留 standard 原始大小写用于替换，variants 小写用于匹配
            entries.append((standard, variants))
        }
        self.hotwords = entries
    }

    /// Apply hotword corrections to the given text.
    func correct(_ text: String) -> String {
        guard !hotwords.isEmpty else { return text }

        var result = text
        for (standard, variants) in hotwords {
            // Apply variant replacements first
            for variant in variants {
                result = replaceIn(result, from: variant, to: standard)
            }
            // Also handle case where the standard form itself might be mis-capitalized
            // (e.g., "openai" -> "OpenAI") — we keep the standard form's original casing
            // but only if the user wrote it with specific casing in the hotword list.
            // Since we lowercased above, we use the user's original input.
        }
        return result
    }

    /// Replace occurrences of `from` in `text` with `to`.
    /// For Chinese/ASCII-mixed text: simple substring replacement.
    /// For purely alphabetic patterns: use word-boundary regex.
    private func replaceIn(_ text: String, from: String, to: String) -> String {
        guard !from.isEmpty else { return text }

        // If the pattern is purely alphabetic (English word), use word boundary
        if from.allSatisfy({ $0.isASCII && $0.isLetter }) {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: from))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                return regex.stringByReplacingMatches(
                    in: text, range: range,
                    withTemplate: to
                )
            }
        }

        // Chinese or mixed: simple case-insensitive substring replacement
        let lowerFrom = from.lowercased()
        var result = text
        var searchRange = result.startIndex..<result.endIndex

        while let foundRange = result[searchRange].lowercased().range(of: lowerFrom) {
            let absoluteRange = foundRange.lowerBound..<foundRange.upperBound
            result.replaceSubrange(absoluteRange, with: to)
            searchRange = absoluteRange.upperBound..<result.endIndex
        }

        return result
    }
}
