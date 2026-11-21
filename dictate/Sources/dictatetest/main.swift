import AVFoundation
import DictateCore
import Foundation

// Mini Dictate self-test.  dictatetest            → formatting rules + safety check (instant, offline)
//                       dictatetest --audio    → also transcribe generated speech (US + Indian-English voices)
//                       dictatetest --ai       → also exercise Apple's on-device model through the safety check
var failures = 0
func expect(_ name: String, _ got: String, _ want: String) {
    if got == want { print("✅ \(name)") } else { failures += 1; print("❌ \(name)\n   want: \(want.debugDescription)\n   got:  \(got.debugDescription)") }
}
func expectTrue(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("✅ \(name)") } else { failures += 1; print("❌ \(name) \(detail)") }
}

print("— eval metrics —")
expectTrue("WER one substitution in three", abs(Eval.wer(reference: "send the report", hypothesis: "send a report") - 1.0 / 3) < 1e-9)
expect("eval words numberized", Eval.words("Twenty five apples, please!").joined(separator: " "), "25 apples please")
let lay = Eval.layout("Intro:\n1. A\n2. B\n\nDone.")
expectTrue("layout counts sentences + items", lay.sentences == 4 && lay.items == 2, "\(lay)")

print("— recognizer joins —")
expect("join adds a space between sentences", SpeechEngine.join("See you next week.", "Next time"), "See you next week. Next time")
expect("join keeps existing space", SpeechEngine.join("Hi", " there"), "Hi there")
expect("join before punctuation", SpeechEngine.join("Hi", ", there"), "Hi, there")
expect("join empty", SpeechEngine.join("", "Hi"), "Hi")

print("— vocabulary —")
Vocabulary.ensureUserFile()
let v = Vocabulary.load()
print("   speech hints: \(v.joined(separator: ", "))")
expectTrue("vocabulary loads (your list + names from Mini's memory)", v.contains("Mini"))

expectTrue("weekdays/months/ordinary words are not names", !Vocabulary.isLikelyName("Monday") && !Vocabulary.isLikelyName("January")
           && !Vocabulary.isLikelyName("Likes") && !Vocabulary.isLikelyName("Works"))
expectTrue("real names are names", Vocabulary.isLikelyName("Rahul") && Vocabulary.isLikelyName("Priya"))

print("— rules —")
expect("fillers removed", Rules.apply("um so I think uh we should go", tone: .neutral), "So I think we should go")
expect("repeated word", Rules.apply("send it to to the team", tone: .neutral), "Send it to the team")
expect("self-correction (number)", Rules.apply("the meeting is at 10, no, actually 11.", tone: .neutral), "The meeting is at 11.")
expect("self-correction (word)", Rules.apply("Send the invoice to the client today or actually tomorrow morning.", tone: .neutral),
       "Send the invoice to the client tomorrow morning.")
expect("spoken new paragraph", Rules.apply("Thanks for the update. new paragraph See you Monday.", tone: .neutral),
       "Thanks for the update.\n\nSee you Monday.")
expect("spoken bullets", Rules.apply("Agenda bullet budget bullet hiring", tone: .neutral), "Agenda\n• Budget\n• Hiring")
expect("ordinal list + greeting + trailing sentence",
       Rules.apply("Hey, Rahul, so for tomorrow, we need 3 things. 1st book the room, 2nd send, the slides and a 3rd order, lunch and the meeting is at 10, no, actually 11.", tone: .neutral),
       "Hey Rahul,\n\nFor tomorrow, we need 3 things:\n1. Book the room\n2. Send the slides\n3. Order lunch\n\nThe meeting is at 11.")
expect("plain sentence untouched", Rules.apply("Can you please send me the quarterly report by Friday and also copy Priya on the email?", tone: .neutral),
       "Can you please send me the quarterly report by Friday and also copy Priya on the email?")
expect("code tone: fillers only", Rules.apply("um git commit dash m first fix", tone: .code), "git commit dash m first fix")
expect("'sorry,' is not a correction", Rules.apply("I'm sorry, I can't make it", tone: .neutral), "I'm sorry, I can't make it")
expect("'I mean' is not a correction", Rules.apply("What I mean is we should wait", tone: .neutral), "What I mean is we should wait")
expect("'period' as a word", Rules.apply("the trial period ends Friday", tone: .neutral), "The trial period ends Friday")
expect("'bullet' as a word", Rules.apply("that was a silver bullet for us", tone: .neutral), "That was a silver bullet for us")
expect("real repetition kept", Rules.apply("I had had enough and that that was it", tone: .neutral), "I had had enough and that that was it")
expect("'first of all' is not a list", Rules.apply("first of all thanks. finally we ship on monday", tone: .neutral),
       "First of all thanks. Finally we ship on monday")
expect("capital after full stop", Rules.apply("ok. see you then. bye", tone: .neutral), "Ok. See you then. Bye")
expect("'comma-separated' as a word", Rules.apply("use comma-separated values", tone: .neutral), "Use comma-separated values")
expect("spoken comma", Rules.apply("hi Alex comma how are you", tone: .neutral), "Hi Alex, how are you")
expect("'no, actually' in ordinary speech", Rules.apply("I said no, actually I'm fine", tone: .neutral), "I said no, actually I'm fine")
expect("'second thought' is not a list", Rules.apply("first, let me check. second thought, never mind", tone: .neutral),
       "First, let me check. Second thought, never mind")
expect("no capital after e.g.", Rules.apply("bring snacks, e.g. chips and fruit", tone: .neutral), "Bring snacks, e.g. chips and fruit")
expect("number correction with 'no wait'", Rules.apply("call me at 5, no wait, 6 o'clock", tone: .neutral), "Call me at 6 o'clock")
expect("spoken period at the end", Rules.apply("send it to me period", tone: .neutral), "Send it to me.")
expectTrue("one ordinal is not a list", Rules.ordinalList("first, let me check the logs") == nil)
expectTrue("AI only for loose lists/long text", !Rules.needsAI("Thanks, see you soon.", tone: .neutral)
           && Rules.needsAI("Groceries we need milk, eggs, bread, and coffee for the week", tone: .neutral)
           && !Rules.needsAI("milk, eggs, bread, and coffee for the whole week please", tone: .code))
expectTrue("AI for run-on sentences", Rules.needsAI("so we should go to the store and then pick up the kids and after that we could grab dinner somewhere nice tonight", tone: .neutral))
expectTrue("no AI for a clean short sentence", !Rules.needsAI("Thanks, see you soon at the cafe tomorrow.", tone: .neutral))
expectTrue("AI for a list without commas", Rules.needsAI("For the trip I need to pack my charger my passport some snacks.", tone: .neutral))
expectTrue("no AI for an ordinary punctuated sentence", !Rules.needsAI("Can you please send me the quarterly report by Friday?", tone: .neutral))
expectTrue("AI for spoken numbers", Rules.needsAI("we need twenty five chairs for the event please", tone: .neutral))
expectTrue("AI for leftover corrections", Rules.needsAI("Let's meet on Tuesday, I mean Wednesday, at the office.", tone: .neutral))
expectTrue("tone from app", Tone.forApp(bundleID: "com.apple.mail") == .formal && Tone.forApp(bundleID: "net.whatsapp.WhatsApp") == .casual
           && Tone.forApp(bundleID: "com.microsoft.VSCode") == .code && Tone.forApp(bundleID: "com.apple.Safari") == .neutral)

print("— names (sounds-alike fix from your list) —")
let names = ["Rahul", "Priya", "Alex", "Mini"]
expect("Rehal -> Rahul", NameFixer.apply("Hey, Rehal, can you call me?", names: names).text, "Hey, Rahul, can you call me?")
expect("casing fixed", NameFixer.apply("tell priya the plan", names: names).text, "tell Priya the plan")
for w in ["Many people came.", "Mine is ready.", "Man, that was fast.", "Main thing is done.", "Pray for rain.", "Prior to that, yes."] {
    expect("capitalised word not turned into a name: \(w)", NameFixer.apply(w, names: names).text, w)
}
expect("ordinary words untouched", NameFixer.apply("the rule is real and I prayed for rain", names: names).text,
       "the rule is real and I prayed for rain")
expect("lowercase i -> I", Rules.apply("yes i think i can do it", tone: .neutral), "Yes I think I can do it")

expect("AI layout polished", DictateFormatter.polish("1. Groceries we need  \n- milk  \n- eggs\n- **bread**"),
       "Groceries we need:\n• Milk\n• Eggs\n• Bread")

print("— safety check —")
let original = "Hey Rahul so for tomorrow we need three things book the room send the slides order lunch and the meeting is at 11"
expectTrue("rejects dropped content", !Faithfulness.check(original: original, formatted: "Hey Rahul\n1. Book the room\n2. Send the slides").ok)
expectTrue("rejects invented content", !Faithfulness.check(original: "Send the report by Friday",
           formatted: "Hey Rahul, please send the quarterly finance report and budget by Friday afternoon").ok)
expectTrue("accepts faithful layout", Faithfulness.check(original: original,
           formatted: "Hey Rahul,\n\nFor tomorrow we need three things:\n1. Book the room\n2. Send the slides\n3. Order lunch\n\nThe meeting is at 11.").ok)

expectTrue("accepts numbers as digits", Faithfulness.check(original: "I need twenty five chairs by friday",
           formatted: "I need 25 chairs by Friday.").ok)
expectTrue("rejects reordered content", !Faithfulness.check(original: "book the room then send the slides then order lunch then call Priya",
           formatted: "Call Priya, order lunch, send the slides, book the room.").ok)

expectTrue("rejects empty AI output", !Faithfulness.check(original: "the the the", formatted: " ").ok)
expectTrue("accepts an applied self-correction", Faithfulness.check(original: "Let's meet on Tuesday, I mean Wednesday, at the office.",
           formatted: "Let's meet on Wednesday at the office.").ok)
expectTrue("still rejects a dropped sentence", !Faithfulness.check(original: "Let's meet on Wednesday at the office. Bring the laptop and the charger.",
           formatted: "Let's meet on Wednesday at the office.").ok)

print("— grammar polish —")
expect("'should of' -> 'should have'", Rules.apply("we should of told them", tone: .neutral), "We should have told them")
expect("'alot' -> 'a lot'", Rules.apply("thanks alot", tone: .neutral), "Thanks a lot")
expect("'would of course' untouched", Rules.apply("I would of course help you", tone: .neutral), "I would of course help you")
expectTrue("'a one-time' / 'a European' are fine", !Rules.hasGrammarSlip("a one-time fee") && !Rules.hasGrammarSlip("a European trip")
           && !Rules.hasGrammarSlip("a unique user") && Rules.hasGrammarSlip("bring a umbrella") && Rules.hasGrammarSlip("a apple"))
expect("code tone keeps 'should of'", Rules.apply("should of", tone: .code), "should of")
expectTrue("AI for a grammar slip in a short sentence", Rules.needsAI("he don't know", tone: .neutral)
           && Rules.needsAI("your welcome to join", tone: .neutral) && Rules.needsAI("they was late", tone: .neutral))
expectTrue("no AI for correct short text", !Rules.needsAI("He doesn't know.", tone: .neutral) && !Rules.needsAI("You're welcome.", tone: .neutral))
expectTrue("accepts small grammar fixes", Faithfulness.check(original: "he don't know where there going with this",
           formatted: "He doesn't know where they're going with this.").ok)
expectTrue("rejects a flipped negation", !Faithfulness.check(original: "send the report to Rahul now",
           formatted: "Don't send the report to Rahul now.").ok)
expectTrue("rejects a changed number", !Faithfulness.check(original: "meet me at 5 near the station", formatted: "Meet me at 6 near the station.").ok)
expectTrue("rejects a dropped name", !Faithfulness.check(original: "tell Rahul the plan for the launch", formatted: "Tell him the plan for the launch.").ok)
expectTrue("rejects an invented phrase next to a grammar fix", !Faithfulness.check(original: "its going to rain so bring a umbrella",
           formatted: "It's going to rain. We need to bring an umbrella.").ok)
expectTrue("accepts it's/an fix", Faithfulness.check(original: "its going to rain so bring a umbrella",
           formatted: "It's going to rain, so bring an umbrella.").ok)
expectTrue("rejects two dropped words in a short text", !Faithfulness.check(original: "buy milk eggs bread and coffee today",
           formatted: "Buy milk and coffee today.").ok)

print("— Fn key —")
expectTrue("missing 🌐 setting = macOS default, not 'Do Nothing'", KeyPolicy.fnAction(from: nil) == -1
           && KeyPolicy.fnAction(from: 0) == 0 && KeyPolicy.fnAction(from: NSNumber(value: 2)) == 2)
expectTrue("conflict when 🌐 does something or Apple Dictation is on", KeyPolicy.fnConflict(fnAction: -1, dictation: false)
           && KeyPolicy.fnConflict(fnAction: 0, dictation: true) && !KeyPolicy.fnConflict(fnAction: 0, dictation: false))
expectTrue("macOS's automatic Escape right after 🌐 is swallowed", KeyPolicy.isAutoEscape(code: 53, sinceFnDown: 0.05)
           && !KeyPolicy.isAutoEscape(code: 53, sinceFnDown: 0.6) && !KeyPolicy.isAutoEscape(code: 12, sinceFnDown: 0.05)
           && !KeyPolicy.isAutoEscape(code: 53, sinceFnDown: -1))

let args = CommandLine.arguments
// --engine dictation: run the speech tests with Apple's DictationTranscriber (in memory only, nothing saved)
if let i = args.firstIndex(of: "--engine"), i + 1 < args.count { UserDefaults.standard.register(defaults: ["engine": args[i + 1]]) }
if args.contains("--audio") {
    print("— real speech model (generated voices) —")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-test")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let clips: [(String, String, String)] = [
        ("Samantha", "Can you please send me the quarterly report by Friday", "quarterly report by friday"),
        ("Rishi", "Please book a meeting room for tomorrow at eleven", "meeting room for tomorrow"),
        ("Tara", "Remind the team that the launch is next Monday", "launch is next monday"),
    ]
    for (voice, text, mustContain) in clips {
        let f = tmp.appendingPathComponent("\(voice).wav")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", f.path, "--data-format=LEI16@16000", text]
        try p.run(); p.waitUntilExit()
        let t0 = Date()
        let heard = (try? await SpeechEngine.transcribe(file: f)) ?? ""
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        expectTrue("\(voice) (\(ms) ms): \(heard)", heard.lowercased().contains(mustContain))
    }
    try? FileManager.default.removeItem(at: tmp)
}

if args.contains("--ai") {
    print("— Apple on-device model through the safety check —")
    if !AIFormatter.shared.isAvailable {
        print("⚠️  Apple Intelligence model not available — Mini Dictate will use rules only")
    } else {
        let r = await DictateFormatter.format("Groceries we need milk, eggs, bread, and coffee for the week", tone: .neutral)
        print("   [\(r.path)]\n\(r.text.split(separator: "\n").map { "   " + $0 }.joined(separator: "\n"))")
        expectTrue("AI result is faithful or safely fell back", r.path.hasPrefix("AI") || r.path.hasPrefix("rules"))
        expectTrue("groceries kept", ["milk", "eggs", "bread", "coffee"].allSatisfy { r.text.lowercased().contains($0) })
    }
}

if args.contains("--live") {
    print("— live streaming path (audio fed in 0.1 s chunks, like the microphone) —")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-live.wav")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "Rishi", "-o", tmp.path, "--data-format=LEI16@44100",
                   "Hey Rahul, for tomorrow we need three things. First book the room, second send the slides, and third order lunch."]
    try p.run(); p.waitUntilExit()
    let file = try AVAudioFile(forReading: tmp)
    let rec = LiveRecognizer()
    try await rec.start(vocab: ["Rahul"], useMicrophone: false)
    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    while file.framePosition < file.length {
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        try file.read(into: buf, frameCount: chunk)
        rec.feed(buf)
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let t0 = Date()
    let heard = await rec.stop()
    let releaseMs = Int(Date().timeIntervalSince(t0) * 1000)
    let r = await DictateFormatter.format(heard, tone: .neutral)
    print("   heard: \(heard)\n   key-release → final text: \(releaseMs) ms · \(r.path)\n\(r.text.split(separator: "\n").map { "   | " + $0 }.joined(separator: "\n"))")
    expectTrue("live path transcribed the message", heard.lowercased().contains("slides") && heard.lowercased().contains("lunch"))
    expectTrue("live path produced a numbered list", r.text.contains("1. ") && r.text.contains("3. "))
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - Regression eval: dictatetest --eval [--audio] [--ai] [--eval-dir <folder of .wav + .txt pairs>]

/// Same streaming path as the microphone: audio fed to LiveRecognizer in 0.1 s chunks.
func liveTranscribe(_ url: URL, vocab: [String]) async throws -> (text: String, releaseMs: Int) {
    let file = try AVAudioFile(forReading: url)
    let rec = LiveRecognizer()
    try await rec.start(vocab: vocab, useMicrophone: false)
    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    while file.framePosition < file.length {
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        try file.read(into: buf, frameCount: chunk)
        rec.feed(buf)
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let t0 = Date()
    let text = await rec.stop()
    return (text, Int(Date().timeIntervalSince(t0) * 1000))
}

struct Score {
    var n = 0, exact = 0, layout = 0, aiUsed = 0, aiRejected = 0, aiMs = 0
    var accuracy = 0.0
    mutating func add(_ got: FormatResult, _ want: String) {
        n += 1
        if got.text == want { exact += 1 }
        let a = Eval.layout(got.text), b = Eval.layout(want)
        if a.sentences == b.sentences && a.items == b.items { layout += 1 }
        accuracy += 1 - min(1, Eval.wer(reference: want, hypothesis: got.text))
        if got.path.hasPrefix("AI") {
            aiUsed += 1
            if let ms = got.path.split(separator: "(").dropFirst().first?.split(separator: " ").first, let v = Int(ms) { aiMs += v }
        }
        if got.path.contains("rejected") { aiRejected += 1 }
    }
    func row(_ label: String) -> String {
        guard n > 0 else { return "| \(label) | 0 | | | | | |" }
        let pct = { (x: Int) in String(format: "%.0f%%", Double(x) * 100 / Double(n)) }
        return "| \(label) | \(n) | \(pct(exact)) | \(String(format: "%.1f%%", accuracy * 100 / Double(n))) | \(pct(layout)) | \(aiUsed) used / \(aiRejected) rejected | \(aiUsed > 0 ? "\(aiMs / aiUsed) ms" : "–") |"
    }
}

if args.contains("--eval") {
    let evalDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("eval")
    let useAI = args.contains("--ai")
    let names = ["Rahul", "Priya", "Alex", "Mini"]
    var table = ["| set | cases | exact | word accuracy | layout match | AI | AI avg |", "|---|---|---|---|---|---|---|"]
    let verbose = args.contains("--verbose")
    func show(_ want: String, _ got: FormatResult) {
        guard verbose, got.text != want else { return }
        print("   ✗ [\(got.path)]\n     want: \(want.debugDescription)\n     got:  \(got.text.debugDescription)")
    }

    print("— eval: formatting (\(useAI ? "rules + AI" : "rules only")) —")
    var fmt = Score()
    for c in Eval.loadCases(evalDir.appendingPathComponent("format-cases.tsv")) {
        let r = await DictateFormatter.format(c[0], tone: .neutral, useAI: useAI, vocabulary: names)
        fmt.add(r, c[1]); show(c[1], r)
    }
    table.append(fmt.row("format-cases\(useAI ? " (AI)" : "")"))

    func speechSet(_ label: String, _ items: [(audio: URL, spoken: String, want: String)]) async {
        var s = Score(), speechWER = 0.0, release = 0
        for it in items {
            guard let heard = try? await liveTranscribe(it.audio, vocab: names) else { continue }
            speechWER += Eval.wer(reference: it.spoken, hypothesis: heard.text)
            release += heard.releaseMs
            let r = await DictateFormatter.format(heard.text, tone: .neutral, useAI: useAI, vocabulary: names)
            s.add(r, it.want)
            if verbose { print("   heard: \(heard.text)") }
            show(it.want, r)
        }
        table.append(s.row(label))
        if s.n > 0 {
            table.append("| ↳ speech WER \(String(format: "%.1f%%", speechWER * 100 / Double(s.n))) · key-release → text \(release / s.n) ms | | | | | | |")
        }
    }

    if args.contains("--audio") {
        print("— eval: speech (synthetic voices, live streaming path) —")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-eval")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var items: [(audio: URL, spoken: String, want: String)] = []
        for (i, c) in Eval.loadCases(evalDir.appendingPathComponent("speech-cases.tsv"), columns: 3).enumerated() {
            let f = tmp.appendingPathComponent("\(i).wav")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", c[0], "-o", f.path, "--data-format=LEI16@16000", c[1]]
            try p.run(); p.waitUntilExit()
            items.append((f, c[1], c[2]))
        }
        await speechSet("speech-cases (synthetic)", items)
        try? FileManager.default.removeItem(at: tmp)
    }

    if let i = args.firstIndex(of: "--eval-dir"), i + 1 < args.count {
        print("— eval: your recordings —")
        let dir = URL(fileURLWithPath: args[i + 1])
        let wavs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["wav", "m4a", "caf", "aiff"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        let items = wavs.compactMap { w -> (audio: URL, spoken: String, want: String)? in
            guard let want = try? String(contentsOf: w.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            else { return nil }
            let t = want.trimmingCharacters(in: .whitespacesAndNewlines)
            return (w, t, t)
        }
        await speechSet("your recordings", items)
    }
    print(table.joined(separator: "\n"))
}

if args.contains("--live") {
    print("— mic start: no lost words, no stuck sessions —")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-preroll.wav")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "Samantha", "-o", tmp.path, "--data-format=LEI16@44100", "Hello Rahul, the launch moves to Friday."]
    try p.run(); p.waitUntilExit()
    // Audio that arrives while the speech model is still loading (you start talking the moment you press Fn) must be kept.
    let file = try AVAudioFile(forReading: tmp)
    let rec = LiveRecognizer()
    try rec.begin(vocab: ["Rahul"], useMicrophone: false)
    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    while file.framePosition < file.length {
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        try file.read(into: buf, frameCount: chunk)
        rec.feed(buf)                                   // no waiting: model may not be ready yet
    }
    let heard = await rec.stop()
    expectTrue("first words kept while the model loads: \(heard)", heard.lowercased().hasPrefix("hello"))
    // Releasing Fn right after pressing it must not leave the microphone running.
    try rec.begin(vocab: [], useMicrophone: false)
    _ = await rec.stop()
    expectTrue("quick release leaves nothing running", !rec.isRunning)
    try rec.begin(vocab: [], useMicrophone: false)
    await rec.cancel()
    expectTrue("cancel right after start leaves nothing running", !rec.isRunning)
    try? FileManager.default.removeItem(at: tmp)
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
