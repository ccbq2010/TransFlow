import Foundation

/// WER/CER 计算器（纯 Swift，无第三方依赖）。
///
/// 用于 TransFlow 识别率自动评测基准（见 docs/autonomous-improvement.md 提示词 A）。
/// - 英文用 **WER**（词级 Levenshtein）：编辑距离 / 参考词数
/// - 中文用 **CER**（字级 Levenshtein）：编辑距离 / 参考字数
///
/// 归一化规则（按提示词 A）：小写、去首尾空格、英文去标点、中文保留字。
public struct WERCalculator: Sendable {

    /// 编辑距离明细：替换 / 插入 / 删除。
    public struct EditBreakdown: Sendable, Equatable {
        public let substitutions: Int
        public let insertions: Int
        public let deletions: Int
        public var total: Int { substitutions + insertions + deletions }
        public init(substitutions: Int, insertions: Int, deletions: Int) {
            self.substitutions = substitutions
            self.insertions = insertions
            self.deletions = deletions
        }
    }

    public init() {}

    // MARK: - Normalization

    /// 归一化：小写；保留字母（含 CJK 汉字，Swift `isLetter` 已覆盖）、数字、空白；
    /// 其余（标点、符号）替换为空格；最后折叠多余空白。
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var rebuilt = ""
        rebuilt.reserveCapacity(lowered.count)
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch.isWhitespace {
                rebuilt.append(ch)
            } else {
                rebuilt.append(" ")
            }
        }
        return rebuilt
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 归一化后的词数组（按空白切分）。英文 WER 使用。
    public static func words(_ text: String) -> [String] {
        let norm = normalize(text)
        guard !norm.isEmpty else { return [] }
        return norm.split(separator: " ").map(String.init)
    }

    /// 归一化后去掉空白的字符数组。中文 CER 使用（每个汉字作为一个单位）。
    public static func characters(_ text: String) -> [Character] {
        Array(normalize(text).filter { !$0.isWhitespace })
    }

    // MARK: - Edit distance with breakdown

    /// 计算把 `reference` 变换为 `hypothesis` 所需的最少编辑操作（替换/插入/删除）。
    /// - 删除 deletion：参考序列里有、假设序列里没有
    /// - 插入 insertion：假设序列里有、参考序列里没有
    /// - 替换 substitution：同一位置两者不同
    public static func editBreakdown<T: Equatable>(reference: [T], hypothesis: [T]) -> EditBreakdown {
        let n = reference.count
        let m = hypothesis.count

        // dp[i][j] = 把 reference[0..<i] 变成 hypothesis[0..<j] 的最少编辑数
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }          // 全部删除
        for j in 0...m { dp[0][j] = j }          // 全部插入
        for i in 1...n {
            for j in 1...m {
                if reference[i - 1] == hypothesis[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]                       // 匹配，无代价
                } else {
                    dp[i][j] = 1 + min(
                        dp[i - 1][j - 1],                             // 替换
                        dp[i - 1][j],                                 // 删除
                        dp[i][j - 1]                                  // 插入
                    )
                }
            }
        }

        // 回溯统计 S/I/D
        var i = n
        var j = m
        var subs = 0, ins = 0, dels = 0
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && reference[i - 1] == hypothesis[j - 1] {
                i -= 1; j -= 1                                            // 匹配
            } else if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + 1 {
                subs += 1; i -= 1; j -= 1                                 // 替换
            } else if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
                dels += 1; i -= 1                                         // 删除
            } else if j > 0 && dp[i][j] == dp[i][j - 1] + 1 {
                ins += 1; j -= 1                                          // 插入
            } else {
                // 理论上不应到达；安全兜底
                if i > 0 { i -= 1 } else { j -= 1 }
            }
        }
        return EditBreakdown(substitutions: subs, insertions: ins, deletions: dels)
    }

    // MARK: - WER / CER

    /// 词错误率（Word Error Rate）= (S + I + D) / 参考词数。
    /// 参考为空时：假设也为空返回 0.0，否则返回 1.0。
    public static func wer(hypothesis: String, reference: String) -> Double {
        let ref = words(reference)
        let hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0.0 : 1.0 }
        let breakdown = editBreakdown(reference: ref, hypothesis: hyp)
        return Double(breakdown.total) / Double(ref.count)
    }

    /// 词错误率明细（含 S/I/D）。
    public static func werBreakdown(hypothesis: String, reference: String) -> (wer: Double, breakdown: EditBreakdown, referenceCount: Int) {
        let ref = words(reference)
        let hyp = words(hypothesis)
        let breakdown = editBreakdown(reference: ref, hypothesis: hyp)
        let wer: Double = ref.isEmpty ? (hyp.isEmpty ? 0.0 : 1.0) : Double(breakdown.total) / Double(ref.count)
        return (wer, breakdown, ref.count)
    }

    /// 字错误率（Character Error Rate）= (S + I + D) / 参考字数。中文主用。
    /// 参考为空时：假设也为空返回 0.0，否则返回 1.0。
    public static func cer(hypothesis: String, reference: String) -> Double {
        let ref = characters(reference)
        let hyp = characters(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0.0 : 1.0 }
        let breakdown = editBreakdown(reference: ref, hypothesis: hyp)
        return Double(breakdown.total) / Double(ref.count)
    }

    /// 字错误率明细（含 S/I/D）。
    public static func cerBreakdown(hypothesis: String, reference: String) -> (cer: Double, breakdown: EditBreakdown, referenceCount: Int) {
        let ref = characters(reference)
        let hyp = characters(hypothesis)
        let breakdown = editBreakdown(reference: ref, hypothesis: hyp)
        let cer: Double = ref.isEmpty ? (hyp.isEmpty ? 0.0 : 1.0) : Double(breakdown.total) / Double(ref.count)
        return (cer, breakdown, ref.count)
    }

    /// 把 0..1 的比率格式化为百分号字符串，如 `12.3%`。
    public static func format(percent ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }
}
