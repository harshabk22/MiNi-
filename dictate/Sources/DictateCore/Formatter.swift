import Foundation

/// What kind of app the text is going into. Decides how much formatting is allowed.
public enum Tone: String, Sendable {
    case formal      // Mail, Outlook: full sentences, greeting on its own line
    case casual      // Messages, WhatsApp, Slack: light touch
    case code        // Terminal, editors: no lists, no capitalisation changes, fillers only
    case neutral

    public static func forApp(bundleID: String?) -> Tone {
        let id = (bundleID ?? "").lowercased()
        if ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman"].contains(where: id.hasPrefix) { return .formal }
        if ["com.apple.mobilesms", "net.whatsapp", "com.tinyspeck.slackmacgap", "com.hnc.discord", "ru.keepcoder.telegram",
            "com.facebook.archon", "desktop.whatsapp"].contains(where: id.hasPrefix) { return .casual }
        if ["com.apple.terminal", "com.googlecode.iterm2", "com.microsoft.vscode", "com.apple.dt.xcode", "com.todesktop",
            "dev.warp", "com.jetbrains", "dev.zed", "com.sublimetext", "co.posit", "com.mitchellh.ghostty"].contains(where: id.hasPrefix) { return .code }
        return .neutral
    }
}

public struct FormatResult: Sendable {
    public let text: String
    public let path: String          // how it was produced, for the history menu and tests
}

/// Deterministic formatting rules: fast (<1 ms), predictable, and they never drop or invent words.
public enum Rules {
    static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    static func sub(_ s: String, _ p: String, _ t: String) -> String {
        re(p).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
    static func has(_ s: String, _ p: String) -> Bool { re(p).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    static let ordinal = "(?:1st|first|2nd|second|3rd|third|4th|fourth|5th|fifth|6th|sixth|finally|lastly)"

    /// um, uh, erm… (Apple's speech model already drops most of these; this catches the rest)
    public static func removeFillers(_ s: String) -> String {
        var t = sub(s, "\\b(um+|uh+|uhm+|erm+|hmm+)\\b[,.]?\\s*", "")
        t = sub(t, "\\b(\\w+)(\\s+\\1\\b)+", "$1")                  // "the the" -> "the"
        return tidy(t)
    }

    /// "new line", "new paragraph", "bullet point" said out loud become real layout.
    public static func spokenCommands(_ s: String) -> String {
        var t = sub(s, ",?\\s*\\bnew paragraph\\b[,.]?\\s*", "\n\n")
        t = sub(t, ",?\\s*\\b(new line|next line)\\b[,.]?\\s*", "\n")
        t = sub(t, ",?\\s*\\b(bullet point|bullet)\\b[,.:]?\\s*", "\n• ")
        t = sub(t, "\\s+\\b(full stop|period)\\b", ".")
        t = sub(t, "\\s+\\bcomma\\b", ",")
        t = sub(t, "\\s+\\bquestion mark\\b", "?")
        t = sub(t, "\\s+\\bexclamation (mark|point)\\b", "!")
        return t
    }

    /// "10, no, actually 11" -> "11". Only the ONE word/number right before the cue is replaced, so nothing big is lost.
    public static func selfCorrections(_ s: String) -> String {
        tidy(sub(s, "\\b[\\w:]+\\s*,?\\s*(?:no,?\\s*actually|or actually|no,? sorry|i mean|no wait|sorry,|scratch that),?\\s+", ""))
    }

    /// "…we need 3 things 1st book the room 2nd send the slides and a 3rd order lunch, and the meeting is at 11"
    /// -> intro line, numbered items, and the trailing sentence kept as its own paragraph.
    public static func ordinalList(_ s: String) -> String? {
        let parts = re("[,.]?\\s*(?:\\band\\s+(?:a\\s+|the\\s+)?)?\\b\(ordinal)\\b[,:]?\\s*")
        let ns = s as NSString
        let matches = parts.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return nil }
        var pieces: [String] = []
        var last = 0
        for m in matches { pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last))); last = m.range.location + m.range.length }
        pieces.append(ns.substring(from: last))
        var intro = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        var items = pieces.dropFirst().map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,.")) }
        guard items.allSatisfy({ !$0.isEmpty }) else { return nil }
        var tail = ""
        if let lastItem = items.last, let r = lastItem.range(of: "\\s*,?\\s*\\band (the|then|also|we|i|it|please)\\b.*$", options: [.regularExpression, .caseInsensitive]) {
            tail = String(lastItem[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            if tail.lowercased().hasPrefix("and ") { tail = String(tail.dropFirst(4)) }
            items[items.count - 1] = String(lastItem[..<r.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }
        items = items.map { sub($0, "^(\\w+), ", "$1 ").trimmingCharacters(in: CharacterSet(charactersIn: " ,")) }
        var greeting = ""
        if let g = intro.range(of: "^(hey|hi|hello|dear)\\s*,?\\s*[\\w'-]+\\s*,?\\s*(so\\s*,?\\s*)?", options: [.regularExpression, .caseInsensitive]) {
            let words = intro[g].components(separatedBy: CharacterSet(charactersIn: " ,")).filter { !$0.isEmpty }
            greeting = "\(words[0].capitalized) \(words[1]),\n\n"
            intro = String(intro[g.upperBound...])
        }
        intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
        var out = greeting
        if !intro.isEmpty { out += capFirst(intro) + ":\n" }
        out += items.enumerated().map { "\($0.offset + 1). \(capFirst($0.element))" }.joined(separator: "\n")
        if !tail.isEmpty { out += "\n\n" + capFirst(tail.trimmingCharacters(in: CharacterSet(charactersIn: "."))) + "." }
        return out
    }

    static func capFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func tidy(_ s: String) -> String {
        var t = sub(s, "[ \\t]{2,}", " ")
        t = sub(t, "\\bi\\b(?=['\\s,.?!]|$)", "I")                     // "i think" -> "I think"
        t = sub(t, " +([,.?!])", "$1")
        t = sub(t, ",([.?!])", "$1")
        t = sub(t, "^[\\s,]+", "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Signals that only a language model can format well (loose lists, long rambling text).
    public static func needsAI(_ s: String, tone: Tone) -> Bool {
        if tone == .code { return false }
        let words = s.split(separator: " ").count
        if words < 8 { return false }
        let looseList = has(s, ",[^,]+,[^,]+,?\\s+and\\b") || has(s, "\\b(three|four|five|\\d+) (things|items|points|steps|tasks)\\b")
            || has(s, "\\b(list|bullet points)\\b")
        return looseList || words > 45
    }

    /// Everything that is certain and fast. Returns nil for the list part if no explicit ordinal list was spoken.
    public static func apply(_ raw: String, tone: Tone) -> String {
        var t = removeFillers(raw)
        if tone == .code { return t }
        t = selfCorrections(t)
        t = spokenCommands(t)
        if let list = ordinalList(t) { t = list }
        return capFirst(t.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The safety check that keeps the AI honest: its output must keep (almost) all of your words and add (almost) none.
public enum Faithfulness {
    static let stop: Set<String> = ["the", "a", "an", "and", "to", "of", "for", "we", "is", "at", "so", "on", "in", "me", "no",
        "actually", "um", "uh", "1st", "2nd", "3rd", "4th", "5th", "first", "second", "third", "fourth", "fifth", "need",
        "things", "i", "mean", "it", "be", "are", "or", "also", "hey", "hi", "hello", "please", "then", "that", "this", "with"]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !stop.contains($0) })
    }

    /// (ok, fraction of your words kept, fraction of output words that are new)
    public static func check(original: String, formatted: String) -> (ok: Bool, kept: Double, added: Double) {
        let a = words(original), b = words(formatted)
        guard !a.isEmpty else { return (true, 1, 0) }
        let kept = Double(a.intersection(b).count) / Double(a.count)
        let added = Double(b.subtracting(a).count) / Double(max(b.count, 1))
        return (kept >= 0.85 && added <= 0.15, kept, added)
    }
}
