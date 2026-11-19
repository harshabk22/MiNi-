import Foundation
import FoundationModels

/// Apple Intelligence's on-device model: used only for what rules can't do (loose lists, long text, tone),
/// always followed by the faithfulness check. Free, on-device, managed by macOS (no RAM in this app).
public final class AIFormatter: @unchecked Sendable {
    public static let shared = AIFormatter()

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func instructions(_ tone: Tone) -> String {
        let style: String
        switch tone {
        case .formal: style = "This goes into an email: complete sentences, put a greeting on its own line followed by a blank line."
        case .casual: style = "This goes into a chat message: keep it short and natural, no greeting changes."
        default: style = "Keep a neutral style."
        }
        return """
        You turn a raw speech transcript into the text the speaker meant to type.
        Hard rules:
        1. Keep EVERY idea and sentence from the transcript. Never drop, summarize, answer, or add anything.
        2. Remove only filler words and false starts.
        3. If the speaker corrects themselves ("X, no, actually Y" or "X, I mean Y"), keep only Y.
        4. If the speaker lists items, put one item per line: numbered ("1.") when they gave an order or said first/second, otherwise bullets ("- "). Keep the sentence that introduces the list and any sentence after it.
        5. Keep the speaker's own words and tone so it still sounds like them — natural and human, not formal or robotic. Use contractions they used.
        6. Fix punctuation and capitalization. Keep names exactly as written. Break long text into short paragraphs.
        \(style)
        Output only the final text, nothing else.
        """
    }

    /// Load the model ahead of time so the first dictation isn't slow.
    public func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: Self.instructions(.neutral)).prewarm()
    }

    /// Returns nil if unavailable, too slow (timeout), or failed.
    public func format(_ text: String, tone: Tone, timeout: Double = 5) async -> String? {
        guard isAvailable else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: Self.instructions(tone))
                return try? await session.respond(to: text, options: GenerationOptions(temperature: 0.2)).content
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// The whole formatting pipeline: rules first, AI only when needed, and the AI is never trusted blindly.
public enum DictateFormatter {
    /// Standard, tidy layout for model output: "•" bullets, no stray spaces, an intro line instead of a lone "1.".
    public static func polish(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: "^\\s*[-*•]\\s+", with: "• ", options: .regularExpression)
            l = l.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)   // no markdown bold
            return l
        }
        // "1. Intro" followed by bullets (and no "2.") is an intro sentence, not a numbered item
        if let first = lines.firstIndex(where: { $0.range(of: "^1\\.\\s", options: .regularExpression) != nil }),
           !lines.contains(where: { $0.hasPrefix("2. ") }),
           lines.dropFirst(first + 1).first(where: { !$0.isEmpty })?.hasPrefix("• ") == true {
            var intro = String(lines[first].dropFirst(3))
            if !intro.hasSuffix(":") { intro += ":" }
            lines[first] = intro.prefix(1).uppercased() + intro.dropFirst()
        }
        lines = lines.map { $0.hasPrefix("• ") ? "• " + $0.dropFirst(2).prefix(1).uppercased() + $0.dropFirst(3) : $0 }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func format(_ raw: String, tone: Tone, useAI: Bool = true, vocabulary: [String] = []) async -> FormatResult {
        let named = NameFixer.apply(raw, names: vocabulary)          // "Rehal" -> "Rahul" (only names that sound alike)
        let ruled = Rules.apply(named.text, tone: tone)
        // A list already made by the rules is final; the AI only handles what the rules can't.
        guard useAI, !ruled.contains("\n1. "), Rules.needsAI(ruled, tone: tone) else {
            return FormatResult(text: ruled, path: ruled.contains("\n") ? "rules (layout)" : "rules")
        }
        let t0 = Date()
        guard let ai = await AIFormatter.shared.format(ruled, tone: tone) else {
            return FormatResult(text: ruled, path: "rules (AI unavailable or slow)")
        }
        let aiClean = polish(ai)
        let check = Faithfulness.check(original: ruled, formatted: aiClean)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if check.ok {
            return FormatResult(text: aiClean, path: String(format: "AI (%d ms, kept %.0f%%, added %.0f%%)", ms, check.kept * 100, check.added * 100))
        }
        return FormatResult(text: ruled, path: String(format: "rules (AI rejected: kept %.0f%%, added %.0f%%)", check.kept * 100, check.added * 100))
    }
}
