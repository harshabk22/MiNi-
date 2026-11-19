import DictateCore
import Foundation

// dictatecli <audio.wav> [mail|chat|code]   — transcribe a recording and show exactly what Mini Dictate would paste.
let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: dictatecli <audio file> [mail|chat|code]"); exit(1)
}
let tone: Tone = args.count > 2 ? ["mail": .formal, "chat": .casual, "code": .code][args[2]] ?? .neutral : .neutral
let t0 = Date()
let raw = try await SpeechEngine.transcribe(file: URL(fileURLWithPath: args[1]), vocab: Vocabulary.load())
let t1 = Date()
let result = await DictateFormatter.format(raw, tone: tone)
let t2 = Date()
print("HEARD: \(raw)")
print(String(format: "speech %.0f ms · formatting %.0f ms · %@", t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, result.path))
print("---- would paste ----\n\(result.text)")
