@preconcurrency import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech-to-text (SpeechAnalyzer). The model is part of macOS; nothing is downloaded by this app.
public enum SpeechEngine {
    public static let locale = Locale(identifier: "en-US")

    /// live: also report partial ("volatile") text while you're still speaking, for the pop-up preview.
    /// Not `.progressiveTranscription`: that preset adds `fastResults`, which Apple documents as less accurate,
    /// and the final text would come from it too. Live partials + full-accuracy finals instead.
    static func makeTranscriber(live: Bool = false) -> SpeechTranscriber {
        live ? SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
             : SpeechTranscriber(locale: locale, preset: .transcription)
    }

    /// Hidden switch for comparing engines on your own voice: `defaults write local.mini.dictate engine dictation`
    /// uses Apple's DictationTranscriber (same models as macOS Dictation); anything else uses SpeechTranscriber.
    public static var useDictation: Bool { UserDefaults.standard.string(forKey: "engine") == "dictation" }

    /// The live recognizer module and its results as (text, isFinal), for whichever engine is selected.
    /// Falls back to SpeechTranscriber if the dictation model isn't installed (never downloads anything).
    static func liveModule() async -> (any SpeechModule, AsyncThrowingStream<(String, Bool), Error>) {
        if useDictation {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults], attributeOptions: [])
            let needsInstall = (try? await AssetInventory.assetInstallationRequest(supporting: [t])) != nil
            if !needsInstall {
                return (t, AsyncThrowingStream { c in
                    Task { do { for try await r in t.results { c.yield((String(r.text.characters), r.isFinal)) }; c.finish() }
                           catch { c.finish(throwing: error) } }
                })
            }
        }
        let t = makeTranscriber(live: true)
        return (t, AsyncThrowingStream { c in
            Task { do { for try await r in t.results { c.yield((String(r.text.characters), r.isFinal)) }; c.finish() }
                   catch { c.finish(throwing: error) } }
        })
    }

    /// Joins recognizer segments so sentences never fuse ("week.Next").
    public static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        if last.isWhitespace || first.isWhitespace || ",.?!;:".contains(first) { return a + b }
        return a + " " + b
    }

    static func context(_ vocab: [String]) -> AnalysisContext {
        let ctx = AnalysisContext()
        if !vocab.isEmpty { ctx.contextualStrings[.general] = vocab }
        return ctx
    }

    /// Transcribe an audio file (used by tests and the command-line tool).
    public static func transcribe(file url: URL, vocab: [String] = []) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context(vocab))
        async let text: String = {
            var s = ""
            for try await r in transcriber.results where r.isFinal { s = SpeechEngine.join(s, String(r.text.characters)) }
            return s
        }()
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One dictation: audio in, text out. Each Fn press gets its own session, so a late cancel or stop of an old
/// press can never touch a new one.
public final class LiveSession: @unchecked Sendable {
    private let lock = NSLock()                         // the mic callback runs on another thread
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var backlog: [AVAudioPCMBuffer] = []        // audio heard before the speech model was ready
    private var analyzer: SpeechAnalyzer?
    private var results: Task<String, Error>?
    fileprivate var setup: Task<Void, Error>?

    fileprivate func attachModel(vocab: [String], partial: (@Sendable (String) -> Void)?) async throws {
        let (module, texts) = await SpeechEngine.liveModule()
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.setContext(SpeechEngine.context(vocab))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw NSError(domain: "MiniDictate", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio format for speech model"])
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        results = Task {
            var s = ""
            for try await (text, isFinal) in texts {
                if isFinal { s = SpeechEngine.join(s, text) } else { partial?(SpeechEngine.join(s, text)) }
            }
            return s
        }
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)
        // From now on audio goes straight to the model; first send what was heard while it loaded.
        lock.withLock {
            target = format
            self.continuation = continuation
            let waiting = backlog; backlog = []
            for b in waiting { if let c = convertLocked(b) { continuation.yield(AnalyzerInput(buffer: c)) } }
        }
    }

    /// Opt-in (`defaults write local.mini.dictate saveClips -bool true`): your recording, kept on this Mac only, so
    /// `dictatetest --eval-dir` can measure accuracy on your own voice. Off by default.
    fileprivate var clip: AVAudioFile?
    public private(set) var clipURL: URL?

    fileprivate func startClip(format: AVAudioFormat) {
        let dir = Vocabulary.folder.appendingPathComponent("clips")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(stamp).caf")
        clip = try? AVAudioFile(forWriting: url, settings: format.settings)
        clipURL = clip == nil ? nil : url
        // keep the newest 50 recordings
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "caf" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(50) {
            let base = old.deletingPathExtension()
            for ext in ["caf", "heard.txt", "txt"] { try? FileManager.default.removeItem(at: base.appendingPathExtension(ext)) }
        }
    }

    /// Saves what the recognizer heard next to the recording (`<clip>.heard.txt`). Copy it to `<clip>.txt` and correct
    /// it to what you said to add the clip to your test set.
    fileprivate func finishClip(heard: String) {
        clip = nil
        guard let clipURL else { return }
        try? heard.write(to: clipURL.deletingPathExtension().appendingPathExtension("heard.txt"), atomically: true, encoding: .utf8)
    }

    /// Audio in. Kept in the backlog until the speech model is ready.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        try? clip?.write(from: buffer)
        lock.withLock {
            guard let continuation else {
                if let copy = Self.copy(buffer) { backlog.append(copy) }   // the mic reuses its buffers
                return
            }
            if let c = convertLocked(buffer) { continuation.yield(AnalyzerInput(buffer: c)) }
        }
    }

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        out.frameLength = b.frameLength
        let n = Int(b.frameLength), channels = Int(b.format.channelCount)
        if let src = b.floatChannelData, let dst = out.floatChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: n) }
        } else if let src = b.int16ChannelData, let dst = out.int16ChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: n) }
        } else if let src = b.int32ChannelData, let dst = out.int32ChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: n) }
        } else { return nil }
        return out
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target else { return nil }
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// Final transcript (waits for a model that is still loading, so audio from a quick press is still used).
    public func finish() async -> String {
        guard (try? await setup?.value) != nil else { return "" }
        lock.withLock { continuation }?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = ((try? await results?.value) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        finishClip(heard: text)
        return text
    }

    /// Throw it away.
    public func cancel() async {
        clip = nil
        if let clipURL { try? FileManager.default.removeItem(at: clipURL) }      // cancelled audio is never kept
        _ = try? await setup?.value
        lock.withLock { continuation }?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
    }
}

/// Live microphone dictation. begin() when Fn goes down (the microphone starts at once, and audio is kept while the
/// speech model loads), detach() when it comes up, then finish() or cancel() that session.
public final class LiveRecognizer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var current: LiveSession?
    private var micStarted = false
    public var isRunning: Bool { current != nil }
    /// Called with partial text while you speak (for a live preview).
    public var onPartial: (@Sendable (String) -> Void)?
    /// Microphone loudness 0…1, about 20 times a second (for the level bars in the pop-up).
    public var onLevel: (@Sendable (Float) -> Void)?

    public init() {}

    /// Starts listening right away. Synchronous, so it can't race with detach(). Throws only if the mic can't start.
    public func begin(vocab: [String], useMicrophone: Bool = true) throws {
        if let old = detach() { Task { await old.cancel() } }
        let session = LiveSession()
        if useMicrophone {
            if UserDefaults.standard.bool(forKey: "saveClips") { session.startClip(format: engine.inputNode.outputFormat(forBus: 0)) }
            try startMicrophone(into: session)
        }
        current = session
        let partial = onPartial
        session.setup = Task { try await session.attachModel(vocab: vocab, partial: partial) }
    }

    /// Ends the current press: stops the microphone now and hands back its session (nil if none).
    public func detach() -> LiveSession? {
        stopMicrophone()
        defer { current = nil }
        return current
    }

    /// Test hook: audio for the current session, through the same path as the microphone.
    public func feed(_ buffer: AVAudioPCMBuffer) { current?.feed(buffer) }

    /// begin() and wait until the speech model is ready (tests, command-line tool).
    public func start(vocab: [String], useMicrophone: Bool = true) async throws {
        try begin(vocab: vocab, useMicrophone: useMicrophone)
        try await current?.setup?.value
    }

    /// Stop listening and return the final transcript.
    public func stop() async -> String { await detach()?.finish() ?? "" }

    /// Throw away what was recorded.
    public func cancel() async { await detach()?.cancel() }

    private func startMicrophone(into session: LiveSession) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        // Without microphone access (or with no input device) macOS reports a 0 Hz / 0-channel format, and
        // installing a tap with it raises an Objective-C exception that kills the app. Refuse cleanly instead.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "MiniDictate", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "No microphone input (\(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch). Allow Microphone for Mini Dictate."])
        }
        input.removeTap(onBus: 0)
        let level = onLevel
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            if let level, let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
                let rms = (sum / Float(buffer.frameLength)).squareRoot()
                level(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40)))   // ~-50 dB…-10 dB -> 0…1
            }
            session.feed(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        micStarted = true
    }

    private func stopMicrophone() {
        guard micStarted else { return }      // never touch the input node unless the mic was used (it can block)
        micStarted = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
