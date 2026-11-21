import Foundation

/// Fixes names the speech model mis-hears, using YOUR list (vocabulary.txt + names from Mini's memory).
/// Approach from contextual-ASR research: only change a word when it SOUNDS like a known name (same phonetic key)
/// and is spelled close to it — and never touch ordinary English words (checked against macOS's word list).
public enum NameFixer {
    /// Ordinary English words: the all-lowercase entries of macOS's word list (proper names like "Rahul" are capitalised
    /// there, so they are not in this set).
    public static let englishWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").filter { $0.first?.isLowercase == true }.map(String.init))
    }()

    /// Simplified Metaphone-style key: first letter kept, similar sounds merged, vowels after the first letter dropped.
    public static func phoneticKey(_ word: String) -> String {
        var w = word.uppercased().filter { $0.isLetter }
        guard let first = w.first else { return "" }
        for (a, b) in [("PH", "F"), ("CK", "K"), ("SCH", "SK"), ("CH", "X"), ("SH", "X"), ("TH", "0"), ("GH", "G"),
                       ("Q", "K"), ("X", "KS"), ("Z", "S"), ("DG", "J")] {
            w = w.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for (i, ch) in w.enumerated() {
            var c = ch
            if c == "C" { c = "K" }
            if i > 0 && "AEIOUYW".contains(c) { continue }
            if out.last == c { continue }
            out.append(c)
        }
        if "AEIOU".contains(first) { out = String(first) + out.dropFirst() }
        return out
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        if a.isEmpty || b.isEmpty { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// Returns the text with mis-heard names corrected, plus the list of changes (for the history tooltip/tests).
    public static func apply(_ text: String, names vocabulary: [String]) -> (text: String, changes: [String]) {
        let names = vocabulary.filter { $0.count >= 3 && $0.first?.isUppercase == true && !$0.contains(" ") }
        guard !names.isEmpty else { return (text, []) }
        let keyed = names.map { ($0, phoneticKey($0)) }
        var changes: [String] = []
        let regex = try! NSRegularExpression(pattern: "\\b[A-Za-z][A-Za-z'-]{2,}\\b")
        let ns = text as NSString
        var out = text
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range)
            if let exact = names.first(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                if exact != word { out = (out as NSString).replacingCharacters(in: m.range, with: exact) }   // fix casing
                continue
            }
            // Real English words are never changed, capitalised or not: "Many" at the start of a sentence is the
            // word "many", not a misheard "Mini". (The speech model already gets names it was hinted right.)
            if englishWords.contains(word.lowercased()) { continue }
            let key = phoneticKey(word)
            let candidates = keyed.filter { $0.1 == key }.map { ($0.0, similarity($0.0, word)) }.filter { $0.1 >= 0.5 }
            if let best = candidates.max(by: { $0.1 < $1.1 }) {
                out = (out as NSString).replacingCharacters(in: m.range, with: best.0)
                changes.append("\(word)→\(best.0)")
            }
        }
        return (out, changes)
    }
}
