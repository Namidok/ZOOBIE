import AppKit
import Testing
@testable import Companion

/// A microphone that hands out fake recordings and notices a second tap on the same input, which
/// AVAudioEngine answers with an uncaught exception (a crash).
@MainActor
final class FakeMicrophone {
    final class Take: Recording {
        let onResult: (String?, Bool) -> Void
        var audioStopped = false
        var cancelled = false

        init(onResult: @escaping (String?, Bool) -> Void) { self.onResult = onResult }
        func stopAudio() { audioStopped = true }
        func cancel() { cancelled = true }
        func hear(_ text: String, final: Bool = false) { onResult(text, final) }
    }

    var takes: [Take] = []
    var secondTap = false

    func record(locale: String, onResult: @escaping (String?, Bool) -> Void, onLevel: @escaping (Float) -> Void) throws -> Recording {
        if takes.contains(where: { !$0.audioStopped }) { secondTap = true }
        let take = Take(onResult: onResult)
        takes.append(take)
        return take
    }
}

@MainActor
private func until(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
}

@MainActor @Suite struct SpeechInputTests {
    let mic = FakeMicrophone()
    let speech: SpeechInput

    init() {
        let mic = mic
        speech = SpeechInput(startRecording: { try mic.record(locale: $0, onResult: $1, onLevel: $2) })
    }

    // F01-H1
    @Test func returnsWhatWasSaid() async throws {
        var partials: [String] = []
        speech.onPartial = { partials.append($0) }
        try speech.start()
        mic.takes[0].hear("what's the weather")
        let text = await speech.stop()
        #expect(text == "what's the weather")
        #expect(partials == ["what's the weather"])
        #expect(mic.takes[0].audioStopped && mic.takes[0].cancelled)
        #expect(!speech.isRunning)
    }

    // F01-E1
    @Test func nothingSaidGivesEmptyText() async throws {
        try speech.start()
        mic.takes[0].hear("", final: true)
        #expect(await speech.stop() == "")
    }

    // F01-E2: emoji and accents survive
    @Test func keepsAccentsAndEmoji() async throws {
        try speech.start()
        mic.takes[0].hear("  Wie spät ist es in Zürich? 🙂 ")
        #expect(await speech.stop() == "Wie spät ist es in Zürich? 🙂")
    }

    // F01-N2: ⌃⌥Space while holding cancels without sending
    @Test func cancelDropsTheRecording() async throws {
        try speech.start()
        mic.takes[0].hear("never mind")
        speech.cancel()
        #expect(!speech.isRunning)
        #expect(mic.takes[0].audioStopped && mic.takes[0].cancelled)
        #expect(await speech.stop() == "")
    }

    // F01-E5 / F03-E1: release ⌃⌥ and talk again at once (or double-click the mic) while the first
    // recording still waits for its final words. Both halves must survive and the new recording must live.
    @Test func talkingAgainRightAwayContinuesTheQuestion() async throws {
        try speech.start()
        let first = mic.takes[0]
        first.hear("open Safari")
        let firstStop = Task { await speech.stop() }
        await until { first.audioStopped }

        try speech.start() // talking again while the first recording finishes
        let second = mic.takes[1]
        second.hear("and play some music")
        let firstText = await firstStop.value

        #expect(!second.cancelled, "the new recording was killed by the old one's cleanup")
        #expect(speech.isRunning)
        let secondText = await speech.stop()
        #expect(firstText.isEmpty, "the first half is carried into the second, not sent on its own")
        #expect(secondText == "open Safari and play some music")
        #expect(!mic.secondTap)
    }

    // F01-E6: a second start while already listening must not tap the microphone twice (crash)
    @Test func startingTwiceKeepsOneRecording() throws {
        try speech.start()
        try speech.start()
        #expect(!mic.secondTap)
        #expect(mic.takes.count == 1)
    }
}

@MainActor @Suite struct ModifierHoldTests {
    let monitor = ModifierHoldMonitor()
    final class Log { var events: [String] = [] }
    let log = Log()

    init() {
        let log = log
        monitor.onBegin = { log.events.append("begin") }
        monitor.onEnd = { log.events.append("end") }
        monitor.onCancel = { log.events.append("cancel") }
    }

    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    // F01-H1
    @Test func holdBeginsAndReleaseEnds() async {
        monitor.flagsChanged([.control, .option])
        await wait(0.35)
        #expect(log.events == ["begin"])
        monitor.flagsChanged([])
        #expect(log.events == ["begin", "end"])
    }

    // F01-E3: a quick tap is not push-to-talk
    @Test func shortTapDoesNothing() async {
        monitor.flagsChanged([.control, .option])
        await wait(0.1)
        monitor.flagsChanged([])
        await wait(0.3)
        #expect(log.events.isEmpty)
    }

    // F01-E4: ⌃⌥→ and other shortcuts keep working
    @Test func keyPressMeansShortcut() async {
        monitor.flagsChanged([.control, .option])
        monitor.keyPressed()
        await wait(0.35)
        #expect(log.events.isEmpty)
    }

    @Test func extraModifierIsNotPushToTalk() async {
        monitor.flagsChanged([.control, .option, .command])
        await wait(0.35)
        #expect(log.events.isEmpty)
    }

    // F01-N2
    @Test func cancelWhileHolding() async {
        monitor.flagsChanged([.control, .option])
        await wait(0.35)
        monitor.cancel()
        monitor.flagsChanged([])
        #expect(log.events == ["begin", "cancel"])
    }

    // Caps Lock or fn being on must not block push-to-talk.
    @Test func ignoresCapsLockAndFn() async {
        monitor.flagsChanged([.control, .option, .capsLock, .function])
        await wait(0.35)
        #expect(log.events == ["begin"])
    }
}
