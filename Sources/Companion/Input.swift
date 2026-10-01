import AppKit
import AVFoundation
import Carbon.HIToolbox
import Speech

// MARK: - Hotkeys

/// A system-wide hotkey via Carbon. Needs no permissions and swallows the key event.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x434D_5041), id: 1) // "CMPA"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Detects holding exactly ⌃⌥ (push-to-talk). A short delay and any key press in between
/// cancel it, so ordinary ⌃⌥-shortcuts keep working. Requires Accessibility permission.
@MainActor
final class ModifierHoldMonitor {
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onCancel: () -> Void = {}

    private let required: NSEvent.ModifierFlags = [.control, .option]
    private let holdDelay: TimeInterval = 0.22
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private(set) var isActive = false

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] event in self?.flagsChanged(event.modifierFlags) }
        let key: (NSEvent) -> Void = { [weak self] _ in self?.keyPressed() }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key),
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key($0); return $0 },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Aborts a pending or active hold without submitting (e.g. ⌃⌥Space was pressed instead).
    func cancel() {
        cancelPending()
        if isActive {
            isActive = false
            onCancel()
        }
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        if flags.intersection([.control, .option, .command, .shift]) == required {
            guard pending == nil, !isActive else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.isActive = true
                self.onBegin()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        } else {
            cancelPending()
            if isActive {
                isActive = false
                onEnd()
            }
        }
    }

    private func keyPressed() {
        // A key while ⌃⌥ is down means a shortcut, not push-to-talk.
        if pending != nil { cancelPending() }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}

// MARK: - Speech in

/// Push-to-talk transcription that never leaves the device (`requiresOnDeviceRecognition`).
@MainActor
final class SpeechInput {
    enum SpeechError: LocalizedError {
        case notAuthorized, microphoneDenied, noMicrophone, onDeviceUnavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Speech recognition is off for ZOOBIE. Enable it in System Settings › Privacy & Security › Speech Recognition."
            case .microphoneDenied: return "Microphone access is off for ZOOBIE. Enable it in System Settings › Privacy & Security › Microphone."
            case .noMicrophone: return "No microphone input is available."
            case .onDeviceUnavailable: return "On-device speech isn't available yet. Turn on Dictation in System Settings › Keyboard to download the model, or type with ⌃⌥Space."
            }
        }
    }

    var onPartial: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    private(set) var isRunning = false

    /// Recognition language: en-US normally, de-DE during German practice.
    var localeIdentifier = "en-US"
    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finalWaiter: CheckedContinuation<Void, Never>?

    static func requestPermissions() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw SpeechError.notAuthorized }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SpeechError.microphoneDenied }
    }

    func start() throws {
        if recognizer?.locale.identifier != localeIdentifier {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { throw SpeechError.onDeviceUnavailable }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.noMicrophone }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = ["Xcode", "Swift", "SwiftUI", "npm", "git", "Ollama", "Python", "TypeScript", "stack trace", "agent"]
        self.request = request
        transcript = ""

        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(request: request, owner: self))
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(owner: self))
        isRunning = true
    }

    /// Stops recording and waits briefly for the final transcription.
    func stop() async -> String {
        guard isRunning else { return "" }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finalWaiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.resumeWaiter() }
        }
        task?.cancel()
        task = nil
        request = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        resumeWaiter()
    }

    private func handle(text: String?, isFinal: Bool) {
        if let text, !text.isEmpty {
            transcript = text
            if isRunning { onPartial(text) }
        }
        if isFinal { resumeWaiter() }
    }

    private func resumeWaiter() {
        finalWaiter?.resume()
        finalWaiter = nil
    }

    // Built outside the main actor: these run on audio / recognition threads.
    nonisolated private static func tapBlock(request: SFSpeechAudioBufferRecognitionRequest, owner: SpeechInput) -> AVAudioNodeTapBlock {
        { [weak owner] buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
            DispatchQueue.main.async { owner?.onLevel(level) }
        }
    }

    nonisolated private static func resultHandler(owner: SpeechInput) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async { owner?.handle(text: text, isFinal: isFinal) }
        }
    }
}
