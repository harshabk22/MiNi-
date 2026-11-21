import Foundation

/// Scoring for the regression set (dictatetest --eval): word error rate after normalisation, and a layout check
/// (sentence and list-item counts), so changes to speech, rules or AI can be measured instead of guessed.
public enum Eval {
    static let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// Spoken numbers to digits: "twenty five" -> "25", "one hundred" -> "100", "eleven" -> "11".
    public static func numberize(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if let n = tens[t] {
                if i + 1 < tokens.count, let u = units[tokens[i + 1]], u > 0, u < 10 { out.append(String(n + u)); i += 2; continue }
                out.append(String(n)); i += 1; continue
            }
            if let n = units[t] {
                if i + 1 < tokens.count, tokens[i + 1] == "hundred" { out.append(String(n * 100)); i += 2; continue }
                out.append(String(n)); i += 1; continue
            }
            out.append(t); i += 1
        }
        return out
    }

    /// Lowercased words without punctuation, spoken numbers as digits ("twenty-five" -> "25").
    public static func words(_ s: String) -> [String] {
        let raw = s.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
        return numberize(raw)
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    /// Word error rate: (substitutions + deletions + insertions) / reference words.
    public static func wer(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(editDistance(r, h)) / Double(r.count)
    }

    static let marker = try! NSRegularExpression(pattern: "^\\s*(?:[•\\-*]|\\d+\\.)\\s+")
    static let stop = try! NSRegularExpression(pattern: "[.?!](?=\\s|$)")

    /// Sentence and list-item counts: the shape of the text, independent of exact wording.
    public static func layout(_ s: String) -> (sentences: Int, items: Int) {
        var sentences = 0, items = 0
        for line in s.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let ns = line as NSString
            var body = line
            if let m = marker.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                items += 1
                body = ns.substring(from: m.range.length)
            }
            let n = stop.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body))
            sentences += max(n, 1)
        }
        return (sentences, items)
    }

    /// Lines of "raw<TAB>expected" (\n written as \\n); # comments and blank lines skipped.
    public static func loadCases(_ url: URL, columns: Int = 2) -> [[String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            let cols = line.components(separatedBy: "\t").map { $0.replacingOccurrences(of: "\\n", with: "\n") }
            return cols.count >= columns ? cols : nil
        }
    }
}
