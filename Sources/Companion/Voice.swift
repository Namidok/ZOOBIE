import AppKit
import AVFoundation
import CompanionCore
import NaturalLanguage

/// Runs the local Kokoro neural TTS server installed by `scripts/setup-voice.sh` and talks to it over
/// 127.0.0.1. If it isn't installed or doesn't answer, narration falls back to an Apple voice.
@MainActor
final class VoiceServer {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Companion/voice")
    nonisolated static let port = 8765

    private(set) var isReady = false
    private(set) var voices: [String] = []
    private var process: Process?

    private var python: URL { Self.directory.appendingPathComponent("venv/bin/python") }
    private var script: URL? { Bundle.main.url(forResource: "kokoro_server", withExtension: "py") }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("kokoro-v1.0.onnx").path)
            && script != nil
    }

    func start() async {
        if await checkHealth() { return } // already running, e.g. left over from a previous launch
        guard isInstalled, let script else { return }
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, Self.directory.path, String(Self.port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        self.process = process
        for _ in 0..<60 { // the model takes a few seconds to load
            try? await Task.sleep(for: .milliseconds(500))
            if await checkHealth() { return }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isReady = false
    }

    private func checkHealth() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        if case .object(let body)? = JSONValue.parse(String(decoding: data, as: UTF8.self)), case .array(let list)? = body["voices"] {
            voices = list.compactMap(\.stringValue)
        }
        isReady = true
        return true
    }

    nonisolated static func synthesize(_ text: String, voice: String, speed: Double) async -> Data? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tts")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: JSONValue] = ["text": .string(text), "voice": .string(voice), "speed": .number(speed)]
        request.httpBody = try? JSONEncoder().encode(body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// Plays a reply sentence by sentence. `onStep` fires as each sentence *starts*, so captions and
/// pointing stay in sync with the voice. Steps can be enqueued while the model is still streaming —
/// neural audio for later sentences is synthesized while earlier ones play. `finishInput()` marks the
/// end, after which `onFinish` fires once everything has played.
@MainActor
final class Narrator: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Engine: Equatable {
        case neural(voice: String)
        case system(name: String)
        /// Captions only, paced by reading time.
        case silent
    }

    var onStep: (NarrationStep) -> Void = { _ in }
    var onFinish: () -> Void = {}
    private(set) var isActive = false
    var isPlaying: Bool { playTask != nil }

    private var engine = Engine.silent
    private var speed = 1.0
    private var session = 0
    private var queue: [(step: NarrationStep, audio: Task<Data?, Never>?, german: Bool)] = []
    private var inputFinished = false
    private var playTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var waiting: (id: ObjectIdentifier, continuation: CheckedContinuation<Void, Never>)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func begin(engine: Engine, speed: Double) {
        stop()
        self.engine = engine
        self.speed = speed
        isActive = true
    }

    func enqueue(_ step: NarrationStep) {
        guard isActive else { return }
        // German sentences (German practice, quotes) are spoken by a German voice instead of the English one.
        let german = engine != .silent && Self.isGerman(step.text)
        var audio: Task<Data?, Never>?
        if !german, case .neural(let voice) = engine {
            let text = step.text, speed = self.speed
            audio = Task.detached(priority: .userInitiated) { await VoiceServer.synthesize(text, voice: voice, speed: speed) }
        }
        queue.append((step, audio, german))
        startPlaybackIfNeeded()
    }

    /// No more steps are coming for this reply.
    func finishInput() {
        guard isActive else { return }
        inputFinished = true
        if playTask == nil && queue.isEmpty { finish() }
    }

    func stop() {
        isActive = false
        session += 1
        inputFinished = false
        queue.forEach { $0.audio?.cancel() }
        queue = []
        playTask?.cancel()
        playTask = nil
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        resumeWaiting(nil)
    }

    private func finish() {
        isActive = false
        onFinish()
    }

    private func startPlaybackIfNeeded() {
        guard playTask == nil, !queue.isEmpty else { return }
        let session = self.session
        playTask = Task { [weak self] in
            while let self, self.session == session, !self.queue.isEmpty {
                let item = self.queue.removeFirst()
                let audio = await item.audio?.value
                guard self.session == session else { return }
                self.onStep(item.step)
                if item.german {
                    await self.speakWithSystemVoice(item.step.text, name: "Anna", language: "de")
                } else {
                    await self.play(item.step.text, audio: audio)
                }
            }
            guard let self, self.session == session else { return }
            self.playTask = nil
            if self.inputFinished { self.finish() }
        }
    }

    private func play(_ text: String, audio: Data?) async {
        switch engine {
        case .neural:
            if let audio, let player = try? AVAudioPlayer(data: audio) {
                player.delegate = self
                self.player = player
                await wait(for: ObjectIdentifier(player)) { if !player.play() { self.resumeWaiting(ObjectIdentifier(player)) } }
                self.player = nil
            } else {
                await speakWithSystemVoice(text, name: "Moira") // neural voice unavailable for this sentence
            }
        case .system(let name):
            await speakWithSystemVoice(text, name: name)
        case .silent:
            let words = text.split(separator: " ").count
            try? await Task.sleep(for: .seconds(max(1.6, Double(words) * 0.3)))
        }
    }

    private func speakWithSystemVoice(_ text: String, name: String, language: String = "en") async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.systemVoice(named: name, language: language)
        utterance.rate = min(0.6, Float(0.5 * speed))
        await wait(for: ObjectIdentifier(utterance)) { self.synthesizer.speak(utterance) }
    }

    private func wait(for id: ObjectIdentifier, start: () -> Void) async {
        await withCheckedContinuation { continuation in
            waiting = (id, continuation)
            start()
        }
    }

    /// Resumes the current wait if `id` matches it (nil resumes unconditionally).
    private func resumeWaiting(_ id: ObjectIdentifier?) {
        guard let current = waiting, id == nil || current.id == id else { return }
        waiting = nil
        current.continuation.resume()
    }

    /// The best installed quality of the named Apple voice, else any decent English one.
    static func systemVoice(named name: String, language: String = "en") -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let named = english.filter { $0.name.localizedCaseInsensitiveContains(name) }
        return (named.isEmpty ? english : named).max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// Confidently German (short sentences are ambiguous, so require a clear majority).
    static func isGerman(_ text: String) -> Bool {
        guard text.split(separator: " ").count >= 2 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .german]
        recognizer.processString(text)
        return (recognizer.languageHypotheses(withMaximum: 2)[.german] ?? 0) > 0.7
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { self.resumeWaiting(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { self.resumeWaiting(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { self.resumeWaiting(id) }
    }
}
