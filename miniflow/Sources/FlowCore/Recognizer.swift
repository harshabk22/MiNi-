@preconcurrency import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech-to-text (SpeechAnalyzer). The model is part of macOS; nothing is downloaded by this app.
public enum SpeechEngine {
    public static let locale = Locale(identifier: "en-US")

    /// live: also report partial ("volatile") text while you're still speaking, for the pop-up preview.
    static func makeTranscriber(live: Bool = false) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: live ? .progressiveTranscription : .transcription)
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
            for try await r in transcriber.results where r.isFinal { s += String(r.text.characters) }
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

/// Live microphone dictation: start() when the key goes down, stop() when it comes up.
public final class LiveRecognizer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, Error>?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    public private(set) var isRunning = false
    /// Called with partial text while you speak (for a live preview).
    public var onPartial: (@Sendable (String) -> Void)?
    /// Microphone loudness 0…1, about 20 times a second (for the level bars in the pop-up).
    public var onLevel: (@Sendable (Float) -> Void)?

    public init() {}

    public func start(vocab: [String], useMicrophone: Bool = true) async throws {
        guard !isRunning else { return }
        let transcriber = SpeechEngine.makeTranscriber(live: true)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(SpeechEngine.context(vocab))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "MiniFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio format for speech model"])
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.analyzer = analyzer
        self.target = format
        let partial = onPartial
        results = Task {
            var s = ""
            for try await r in transcriber.results {
                if r.isFinal { s += String(r.text.characters) } else { partial?(s + String(r.text.characters)) }
            }
            return s
        }
        try await analyzer.start(inputSequence: stream)
        guard useMicrophone else { isRunning = true; return }   // tests feed audio with feed(_:)

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        // Without microphone access (or with no input device) macOS reports a 0 Hz / 0-channel format, and
        // installing a tap with it raises an Objective-C exception that kills the app. Refuse cleanly instead.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            await analyzer.cancelAndFinishNow()
            self.analyzer = nil; self.continuation = nil; results?.cancel(); results = nil
            throw NSError(domain: "MiniFlow", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "No microphone input (\(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch). Allow Microphone for Mini Flow."])
        }
        converter = AVAudioConverter(from: inFormat, to: format)
        input.removeTap(onBus: 0)
        let level = onLevel
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            if let level, let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
                let rms = (sum / Float(buffer.frameLength)).squareRoot()
                level(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40)))   // ~-50 dB…-10 dB -> 0…1
            }
            guard let self, let converted = self.convert(buffer) else { return }
            self.continuation?.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Test hook: push audio through exactly the same conversion + streaming path the microphone uses.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        if converter == nil, let target { converter = AVAudioConverter(from: buffer.format, to: target) }
        if let converted = convert(buffer) { continuation?.yield(AnalyzerInput(buffer: converted)) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let target else { return nil }
        if buffer.format == target { return buffer }
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

    /// Stop listening and return the final transcript.
    public func stop() async -> String {
        guard isRunning else { return "" }
        isRunning = false
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = (try? await results?.value) ?? ""
        analyzer = nil; continuation = nil; results = nil; converter = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Throw away what was recorded (Esc while holding the key).
    public func cancel() async {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
        analyzer = nil; continuation = nil; results = nil
    }
}
