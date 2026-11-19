import AVFoundation
import FlowCore
import Foundation

// Mini Flow self-test.  flowtest            → formatting rules + safety check (instant, offline)
//                       flowtest --audio    → also transcribe generated speech (US + Indian-English voices)
//                       flowtest --ai       → also exercise Apple's on-device model through the safety check
var failures = 0
func expect(_ name: String, _ got: String, _ want: String) {
    if got == want { print("✅ \(name)") } else { failures += 1; print("❌ \(name)\n   want: \(want.debugDescription)\n   got:  \(got.debugDescription)") }
}
func expectTrue(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("✅ \(name)") } else { failures += 1; print("❌ \(name) \(detail)") }
}

print("— vocabulary —")
Vocabulary.ensureUserFile()
let v = Vocabulary.load()
print("   speech hints: \(v.joined(separator: ", "))")
expectTrue("vocabulary loads (your list + names from Mini's memory)", v.contains("Mini"))

print("— rules —")
expect("fillers removed", Rules.apply("um so I think uh we should go", tone: .neutral), "So I think we should go")
expect("repeated word", Rules.apply("send it to to the team", tone: .neutral), "Send it to the team")
expect("self-correction (number)", Rules.apply("the meeting is at 10, no, actually 11.", tone: .neutral), "The meeting is at 11.")
expect("self-correction (word)", Rules.apply("Send the invoice to the client today or actually tomorrow morning.", tone: .neutral),
       "Send the invoice to the client tomorrow morning.")
expect("spoken new paragraph", Rules.apply("Thanks for the update. new paragraph See you Monday.", tone: .neutral),
       "Thanks for the update.\n\nSee you Monday.")
expect("spoken bullets", Rules.apply("Agenda bullet budget bullet hiring", tone: .neutral), "Agenda\n• budget\n• hiring")
expect("ordinal list + greeting + trailing sentence",
       Rules.apply("Hey, Rahul, so for tomorrow, we need 3 things. 1st book the room, 2nd send, the slides and a 3rd order, lunch and the meeting is at 10, no, actually 11.", tone: .neutral),
       "Hey Rahul,\n\nFor tomorrow, we need 3 things:\n1. Book the room\n2. Send the slides\n3. Order lunch\n\nThe meeting is at 11.")
expect("plain sentence untouched", Rules.apply("Can you please send me the quarterly report by Friday and also copy Priya on the email?", tone: .neutral),
       "Can you please send me the quarterly report by Friday and also copy Priya on the email?")
expect("code tone: fillers only", Rules.apply("um git commit dash m first fix", tone: .code), "git commit dash m first fix")
expectTrue("one ordinal is not a list", Rules.ordinalList("first, let me check the logs") == nil)
expectTrue("AI only for loose lists/long text", !Rules.needsAI("Thanks, see you soon.", tone: .neutral)
           && Rules.needsAI("Groceries we need milk, eggs, bread, and coffee for the week", tone: .neutral)
           && !Rules.needsAI("milk, eggs, bread, and coffee for the whole week please", tone: .code))
expectTrue("tone from app", Tone.forApp(bundleID: "com.apple.mail") == .formal && Tone.forApp(bundleID: "net.whatsapp.WhatsApp") == .casual
           && Tone.forApp(bundleID: "com.microsoft.VSCode") == .code && Tone.forApp(bundleID: "com.apple.Safari") == .neutral)

print("— names (sounds-alike fix from your list) —")
let names = ["Rahul", "Priya", "Alex", "Mini"]
expect("Rehal -> Rahul", NameFixer.apply("Hey, Rehal, can you call me?", names: names).text, "Hey, Rahul, can you call me?")
expect("casing fixed", NameFixer.apply("tell priya the plan", names: names).text, "tell Priya the plan")
expect("ordinary words untouched", NameFixer.apply("the rule is real and I prayed for rain", names: names).text,
       "the rule is real and I prayed for rain")
expect("lowercase i -> I", Rules.apply("yes i think i can do it", tone: .neutral), "Yes I think I can do it")

expect("AI layout polished", FlowFormatter.polish("1. Groceries we need  \n- milk  \n- eggs\n- **bread**"),
       "Groceries we need:\n• Milk\n• Eggs\n• Bread")

print("— safety check —")
let original = "Hey Rahul so for tomorrow we need three things book the room send the slides order lunch and the meeting is at 11"
expectTrue("rejects dropped content", !Faithfulness.check(original: original, formatted: "Hey Rahul\n1. Book the room\n2. Send the slides").ok)
expectTrue("rejects invented content", !Faithfulness.check(original: "Send the report by Friday",
           formatted: "Hey Rahul, please send the quarterly finance report and budget by Friday afternoon").ok)
expectTrue("accepts faithful layout", Faithfulness.check(original: original,
           formatted: "Hey Rahul,\n\nFor tomorrow we need three things:\n1. Book the room\n2. Send the slides\n3. Order lunch\n\nThe meeting is at 11.").ok)

let args = CommandLine.arguments
if args.contains("--audio") {
    print("— real speech model (generated voices) —")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("miniflow-test")
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
        print("⚠️  Apple Intelligence model not available — Mini Flow will use rules only")
    } else {
        let r = await FlowFormatter.format("Groceries we need milk, eggs, bread, and coffee for the week", tone: .neutral)
        print("   [\(r.path)]\n\(r.text.split(separator: "\n").map { "   " + $0 }.joined(separator: "\n"))")
        expectTrue("AI result is faithful or safely fell back", r.path.hasPrefix("AI") || r.path.hasPrefix("rules"))
        expectTrue("groceries kept", ["milk", "eggs", "bread", "coffee"].allSatisfy { r.text.lowercased().contains($0) })
    }
}

if args.contains("--live") {
    print("— live streaming path (audio fed in 0.1 s chunks, like the microphone) —")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("miniflow-live.wav")
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
    let r = await FlowFormatter.format(heard, tone: .neutral)
    print("   heard: \(heard)\n   key-release → final text: \(releaseMs) ms · \(r.path)\n\(r.text.split(separator: "\n").map { "   | " + $0 }.joined(separator: "\n"))")
    expectTrue("live path transcribed the message", heard.lowercased().contains("slides") && heard.lowercased().contains("lunch"))
    expectTrue("live path produced a numbered list", r.text.contains("1. ") && r.text.contains("3. "))
    try? FileManager.default.removeItem(at: tmp)
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
