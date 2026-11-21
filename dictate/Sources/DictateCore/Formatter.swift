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

    static let ordinal = "(?:1st|first|2nd|second|3rd|third|4th|fourth|5th|fifth|6th|sixth|finally|lastly)(?!\\s+(?:of all|thought|time|place|thing|class|half|hand|name|floor|day|week|year|world|aid))"

    /// um, uh, erm… (Apple's speech model already drops most of these; this catches the rest)
    public static func removeFillers(_ s: String) -> String {
        var t = sub(s, "\\b(um+|uh+|uhm+|erm+|hmm+)\\b[,.]?\\s*", "")
        // "the the" -> "the", but real repetition ("had had", "that that") is kept
        t = sub(t, "\\b(?!(?:had|that|very|really|so|no|yes|bye|ha|ok)\\b)(\\w+)(\\s+\\1\\b)+", "$1")
        return tidy(t)
    }

    /// Words before a command word that mean it is just a word ("a silver bullet", "the comma").
    static let notCommand = "(?<!\\b(?:a|an|the|this|that|silver|magic|rubber|single|one|no|my|your|trial|grace|waiting|time)\\s)"

    /// "new line", "new paragraph", "bullet point" said out loud become real layout.
    public static func spokenCommands(_ s: String) -> String {
        var t = sub(s, ",?\\s*\\bnew paragraph\\b[,.]?\\s*", "\n\n")
        t = sub(t, ",?\\s*\\b(new line|next line)\\b[,.]?\\s*", "\n")
        t = sub(t, ",?\\s*\(notCommand)\\b(bullet point|bullet)\\b[,.:]?\\s*", "\n• ")
        // "period" is only punctuation at the end, before a line break or before a new capitalised sentence
        t = sub(t, "\\s*\(notCommand)\\b(full stop|period)\\b[.]?(?=\\s*$|\\s*\\n|\\s+(?-i:[A-Z]))", ".")
        t = sub(t, "\\s+\(notCommand)\\bcomma\\b(?!-)", ",")
        t = sub(t, "\\s+\(notCommand)\\bquestion mark\\b", "?")
        t = sub(t, "\\s+\(notCommand)\\bexclamation (mark|point)\\b", "!")
        return t
    }

    /// "10, no, actually 11" -> "11". Only the ONE word/number right before the cue is replaced, so nothing big is lost.
    /// Only unambiguous cues: "I mean", "sorry" and "no wait" are often ordinary speech, so the AI handles those.
    public static func selfCorrections(_ s: String) -> String {
        var t = sub(s, "\\b\\d[\\d:.]*\\s*,?\\s*(?:no,?\\s*actually|or actually|no,?\\s*wait),?\\s+(?=\\d)", "")   // "10, no actually 11"
        t = sub(t, "\\b[\\w:]+\\s*,?\\s*(?:or actually|scratch that),?\\s+", "")                           // "today or actually tomorrow"
        return tidy(t)
    }

    /// Unambiguous grammar slips that never need the AI: "should of" -> "should have", "alot" -> "a lot".
    public static func grammar(_ s: String) -> String {
        var t = sub(s, "\\b(should|could|would|must|might)\\s+of\\b(?!\\s+course)", "$1 have")
        t = sub(t, "\\b(a)lot\\b", "$1 lot")
        return t
    }

    /// Common grammar slips only the AI can fix (they depend on the sentence): he don't, they was, your welcome…
    public static func hasGrammarSlip(_ s: String) -> Bool {
        has(s, "\\b(he|she|it) don't\\b|\\b(they|we|you) was\\b|\\bthere (going|gonna|coming)\\b"
            + "|\\btheir (is|are|was|going)\\b|\\byour (welcome|going|gonna|right)\\b"
            + "|\\bits (a|an|the|going|been|not|so|very|time)\\b|\\ba (?!one|once|eu|uni|use|usu|uti|ura|uri|uro|ubi)(?:a|e|i|o|u)[a-z]+")
    }

    /// Capital letter at the start of each sentence, line and list item.
    public static func capitalizeSentences(_ s: String) -> String {
        let r = try! NSRegularExpression(pattern: "(^|(?<!\\be\\.g|\\bi\\.e|\\bvs|\\betc)[.?!]\\s+|\\n(?:• |\\d+\\. )?)([a-z])")
        var out = s
        for m in r.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let range = Range(m.range(at: 2), in: out)!
            out.replaceSubrange(range, with: out[range].uppercased())
        }
        return out
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

    /// Signals that only a language model can format well: loose lists, run-on sentences, self-corrections the rules
    /// leave alone, spoken numbers, long text. Clean short sentences skip the AI (it costs ~1–3 s).
    public static func needsAI(_ s: String, tone: Tone) -> Bool {
        if tone == .code { return false }
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if words >= 3 && hasGrammarSlip(s) { return true }
        if words < 8 { return false }
        let looseList = has(s, ",[^,]+,[^,]+,?\\s+and\\b") || has(s, "\\b(three|four|five|\\d+) (things|items|points|steps|tasks)\\b")
            || has(s, "\\b(list|bullet points)\\b")
        let runOn = s.components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
            .contains { $0.split(separator: " ").count >= 20 }
        let correction = has(s, "\\b(i mean|no wait|sorry|scratch that|actually)\\b")
        let listCues = re("\\b(and also|also|then|next|another thing)\\b").numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) >= 2
        let num = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million)"
        let spokenNumber = has(s, "\\b\(num)\\s+\(num)\\b")
        let unpunctuated = !has(s, "[.?!,]")
        // "my charger my passport some snacks": three noun phrases in a row without commas
        let det = "(?:my|your|our|the|some|a|an|his|her|their)"
        let bareList = has(s, "\\b\(det)\\s+\\w+\\s+\(det)\\s+\\w+\\s+(?:and\\s+)?\(det)\\s+\\w+")
        return looseList || runOn || correction || listCues || spokenNumber || unpunctuated || bareList || words > 45
    }

    /// Everything that is certain and fast. Returns nil for the list part if no explicit ordinal list was spoken.
    public static func apply(_ raw: String, tone: Tone) -> String {
        var t = removeFillers(raw)
        if tone == .code { return t }
        t = selfCorrections(t)
        t = grammar(t)
        t = spokenCommands(t)
        if let list = ordinalList(t) { t = list }
        return capitalizeSentences(t.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The safety check that keeps the AI honest: its output must keep (almost) all of your words and add (almost) none.
public enum Faithfulness {
    static let stop: Set<String> = ["the", "a", "an", "and", "to", "of", "for", "we", "is", "at", "so", "on", "in", "me", "no",
        "actually", "um", "uh", "1st", "2nd", "3rd", "4th", "5th", "first", "second", "third", "fourth", "fifth", "need",
        "things", "i", "mean", "it", "be", "are", "or", "also", "hey", "hi", "hello", "please", "then", "that", "this", "with"]

    /// Content words in order (numbers as digits, so "twenty five" and "25" count as the same word).
    static func words(_ s: String) -> [String] {
        let noMarkers = s.replacingOccurrences(of: "(?m)^\\s*(?:\\d+\\.|[-•*])\\s+", with: "", options: .regularExpression)
        return Eval.words(noMarkers).filter { $0.count > 1 && !stop.contains($0) || $0.first?.isNumber == true }
    }

    /// Longest common subsequence length: words kept in the same order.
    static func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1), cur = prev
        for i in 1...a.count {
            for j in 1...b.count { cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1]) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// (ok, fraction of your words kept in order, fraction of output words that are new or moved)
    /// The original as the speaker meant it: "Tuesday, I mean Wednesday" -> "Wednesday", fillers out. The AI is allowed
    /// to apply these, so they don't count as dropped words.
    static func intended(_ s: String) -> String {
        var t = Rules.sub(s, "\\b[\\w:']+\\s*[,.]?\\s*(?:no,?\\s*actually|or actually|i mean|no,?\\s*wait|no,? sorry|scratch that)[,.]?\\s+", "")
        t = Rules.sub(t, "\\b(basically|you know|like,|um+|uh+)\\b[,]?\\s*", "")
        return t
    }

    public static func check(original: String, formatted: String) -> (ok: Bool, kept: Double, added: Double) {
        if formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (false, 0, 0) }
        let literal = score(original: original, formatted: formatted)
        if literal.ok && sameMeaning(original, formatted) { return literal }
        let meantText = intended(original)
        let meant = score(original: meantText, formatted: formatted)
        if meant.ok && sameMeaning(meantText, formatted) { return meant }
        return (false, literal.kept, literal.added)
    }

    static let negations: Set<String> = ["not", "no", "never", "nothing", "none", "nobody", "nowhere", "neither", "nor", "cannot"]

    static func negationCount(_ s: String) -> Int {
        Eval.words(s).filter { negations.contains($0) || $0.hasSuffix("n't") }.count
    }

    /// Names and other capitalised words that are not at the start of a sentence ("Rahul", "Friday").
    static func names(_ s: String) -> Set<String> {
        let r = try! NSRegularExpression(pattern: "(?<![.?!:]\\s)(?<![.?!:])(?<!^)(?<!\\n)(?<!\\n• )(?<!\\d\\.\\s)\\b([A-Z][a-zA-Z'-]+)", options: [.anchorsMatchLines])
        let ns = s as NSString
        return Set(r.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)).lowercased() }
            .filter { $0 != "i" && !$0.hasPrefix("i'") })
    }

    /// Hard rules no rewrite may break: same numbers, same names, same number of negations ("not", "don't"…).
    static func sameMeaning(_ original: String, _ formatted: String) -> Bool {
        let num = { (s: String) in Set(Eval.words(s.replacingOccurrences(of: "(?m)^\\s*\\d+\\.\\s+", with: "", options: .regularExpression))
            .filter { $0.first?.isNumber == true }) }
        guard num(original) == num(formatted) else { return false }
        // Nothing invented: at most 1 extra word (10% for long text) counting every word, even "we", "need", "to",
        // which the word check ignores. Covers "you're" -> "you are"; blocks "so bring" -> "we need to bring".
        let strip = { (s: String) in Eval.words(s.replacingOccurrences(of: "(?m)^\\s*(?:\\d+\\.|[-•*])\\s+", with: "", options: .regularExpression)).count }
        let grown = strip(formatted) - strip(original)
        guard Double(grown) <= max(1, Double(strip(original)) * 0.10) else { return false }
        let out = Set(Eval.words(formatted))
        guard names(original).allSatisfy({ out.contains($0) }) else { return false }
        return negationCount(original) == negationCount(formatted)
    }

    static func score(original: String, formatted: String) -> (ok: Bool, kept: Double, added: Double) {
        let a = words(original), b = words(formatted)
        guard !a.isEmpty else { return (true, 1, 0) }
        let common = lcs(a, b)
        let kept = Double(common) / Double(a.count)
        let added = Double(b.count - common) / Double(max(b.count, 1))
        if kept >= 0.85 && added <= 0.15 { return (true, kept, added) }
        // Grammar fixes swap a word or two for a close form ("don't" -> "doesn't", "there" -> "they're"):
        // allowed only when every missing word was replaced by a similar-looking one, never just dropped.
        let missing = a.filter { !b.contains($0) }, extra = b.filter { !a.contains($0) }
        let swaps = a.count - common <= 2 && a.count - common == b.count - common && missing.count == extra.count
            && missing.allSatisfy { m in extra.contains { NameFixer.similarity(m, $0) >= 0.5 } }
            && extra.allSatisfy { e in missing.contains { NameFixer.similarity(e, $0) >= 0.5 } }
        return (swaps, kept, added)
    }
}
