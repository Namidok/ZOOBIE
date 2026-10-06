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
///
/// Listens through a listen-only CGEvent tap — it only observes, never changes or blocks a key —
/// which catches modifier-only shortcuts more reliably while other apps are in front than AppKit's
/// global monitors. Falls back to those monitors if the tap can't be created.
@MainActor
final class ModifierHoldMonitor {
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onCancel: () -> Void = {}

    private let required: NSEvent.ModifierFlags = [.control, .option]
    private let holdDelay: TimeInterval = 0.22
    private var monitors: [Any] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pending: DispatchWorkItem?
    private(set) var isActive = false

    func start() {
        stop()
        if startEventTap() { return }
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
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// Without Accessibility permission this fails; the app calls `start()` again once it's granted.
    private func startEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, owner in
                // The tap's run loop source is on the main run loop, so this runs on the main thread.
                if let owner {
                    let monitor = Unmanaged<ModifierHoldMonitor>.fromOpaque(owner).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.handle(type, event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .flagsChanged:
            // CGEventFlags and NSEvent.ModifierFlags share the device-independent modifier bits.
            flagsChanged(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
        case .keyDown:
            keyPressed()
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS pauses a tap that it thinks is stuck; switch it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    /// Aborts a pending or active hold without submitting (e.g. ⌃⌥Space was pressed instead).
    func cancel() {
        cancelPending()
        if isActive {
            isActive = false
            onCancel()
        }
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
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

    func keyPressed() {
        // A key while ⌃⌥ is down means a shortcut, not push-to-talk.
        if pending != nil { cancelPending() }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}

// MARK: - Speech in

/// One recording: the microphone feeding the recognizer. `Microphone` makes the real ones; tests use fakes.
@MainActor
protocol Recording: AnyObject {
    /// Stops the microphone and marks the end of the audio. The final words may still arrive.
    func stopAudio()
    /// Stops recognition: no more results.
    func cancel()
}

/// Starts a recording in a language; results (text, isFinal) and mic levels arrive on the main thread.
typealias StartRecording = @MainActor (
    _ locale: String, _ onResult: @escaping (String?, Bool) -> Void, _ onLevel: @escaping (Float) -> Void
) throws -> Recording

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
    var isRunning: Bool { current != nil }

    /// Recognition language: en-US normally, de-DE during German practice.
    var localeIdentifier = "en-US"
    private let startRecording: StartRecording
    /// The recording the microphone feeds now.
    private var current: Take?
    /// The last recording, stopped and waiting for its final words.
    private var finishing: Take?

    /// One recording and its words. Each keeps its own, so a recording still finishing can't touch the next.
    private final class Take {
        var recording: Recording?
        var transcript = ""
        /// Words from a recording the user talked straight on from (released ⌃⌥ and held it again).
        var carried = ""
        /// Set when a new recording starts before this one finished: its words go there instead.
        var continuedBy: Take?
        var finalWaiter: CheckedContinuation<Void, Never>?

        var text: String {
            [carried, transcript].filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func resumeWaiter() {
            finalWaiter?.resume()
            finalWaiter = nil
        }
    }

    init(startRecording: StartRecording? = nil) {
        self.startRecording = startRecording ?? Microphone().record
    }

    static func requestPermissions() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw SpeechError.notAuthorized }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SpeechError.microphoneDenied }
    }

    /// Starts listening. Already listening: nothing to do (the microphone takes only one tap).
    /// If the last recording is still waiting for its final words, this one continues it.
    func start() throws {
        guard current == nil else { return }
        let take = Take()
        take.recording = try startRecording(
            localeIdentifier,
            { [weak self, weak take] text, isFinal in
                guard let self, let take else { return }
                handle(text: text, isFinal: isFinal, in: take)
            },
            { [weak self] level in self?.onLevel(level) }
        )
        current = take
        if let finishing {
            finishing.continuedBy = take
            finishing.resumeWaiter() // its latest words stand; they lead this recording's
        }
    }

    /// Stops recording and waits briefly for the final transcription. The live partial result is
    /// almost always complete already, so it waits only 0.4 s for the final one (1.2 s if nothing
    /// was heard yet) — every bit of this wait is added to the reply.
    /// Returns "" when the user started talking again meanwhile: the words carry into that recording.
    func stop() async -> String {
        guard let take = current else { return "" }
        current = nil
        finishing = take
        take.recording?.stopAudio()
        let wait = take.transcript.isEmpty ? 1.2 : 0.4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            take.finalWaiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { take.resumeWaiter() }
        }
        take.recording?.cancel()
        if finishing === take { finishing = nil }
        if let next = take.continuedBy {
            next.carried = take.text
            if next === current { onPartial(next.text) }
            return ""
        }
        return take.text
    }

    func cancel() {
        guard let take = current else { return }
        current = nil
        take.recording?.stopAudio()
        take.recording?.cancel()
        take.resumeWaiter()
    }

    private func handle(text: String?, isFinal: Bool, in take: Take) {
        if let text, !text.isEmpty {
            take.transcript = text
            if take === current { onPartial(take.text) }
        }
        if isFinal { take.resumeWaiter() }
    }
}

/// The real microphone and on-device recognizer. One audio engine serves every recording; a
/// recording removes its tap in `stopAudio()`, before the next one can install its own.
@MainActor
final class Microphone {
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?

    func record(locale: String, onResult: @escaping (String?, Bool) -> Void, onLevel: @escaping (Float) -> Void) throws -> Recording {
        if recognizer?.locale.identifier != locale {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { throw SpeechInput.SpeechError.onDeviceUnavailable }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechInput.SpeechError.noMicrophone }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = ["Xcode", "Swift", "SwiftUI", "npm", "git", "Ollama", "Python", "TypeScript", "stack trace", "agent"]

        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(request: request, onLevel: onLevel))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        let task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(onResult))
        return LiveRecording(engine: engine, request: request, task: task)
    }

    private final class LiveRecording: Recording {
        let engine: AVAudioEngine
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask

        init(engine: AVAudioEngine, request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask) {
            self.engine = engine
            self.request = request
            self.task = task
        }

        func stopAudio() {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            request.endAudio()
        }

        func cancel() { task.cancel() }
    }

    // Built outside the main actor: these run on audio / recognition threads.
    nonisolated private static func tapBlock(request: SFSpeechAudioBufferRecognitionRequest, onLevel: @escaping (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    nonisolated private static func resultHandler(_ onResult: @escaping (String?, Bool) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async { onResult(text, isFinal) }
        }
    }
}
