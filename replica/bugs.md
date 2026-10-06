# Bugs: ZOOBIE (Clicky features)

From `/replica-test` on 2026-10-06. Cases are in `test-plan.md`. Only reproduced bugs are listed; "To check" holds suspicions that are not reproduced yet.

| ID | severity | title | status |
| --- | --- | --- | --- |
| BUG-001 | S2 | Talking again right after releasing ⌃⌥ sends the wrong words and leaves the mic on | fixed in 90aa607 |
| BUG-002 | S2 | A second start while listening taps the microphone twice (AVAudioEngine crash) | fixed in 90aa607 |
| BUG-003 | S3 | Long reply sentences are cut off in the cursor bubble while still being spoken | open |

### BUG-001: Talking again right after releasing ⌃⌥ sends the wrong words and leaves the mic on

- Severity: S2
- Flow / case: F01 / F01-E5, F03 / F03-E1
- Screen: S02 (cursor overlay), chat window mic button
- Build: 6a263ed  Device: MacBook, macOS 26 (Darwin 25.6)

Steps
1. Hold ⌃⌥, say "open Safari", release.
2. Within about 0.4 s (1.2 s if nothing was recognised yet), hold ⌃⌥ again and say "and play some music". Or double-click the mic button while it is listening.
3. Release.

Expected: one question, "open Safari and play some music", and the mic off afterwards.
Actual: the first release sends "and play some music" (the second recording's words) and "open Safari" is lost. The first recording's cleanup also cancels the second recording's recognizer, so the second release sends nothing. The microphone is left running while the buddy shows idle.
Evidence: `SpeechInputTests.talkingAgainRightAwayContinuesTheQuestion` failed on 6a263ed with `!second.cancelled` false, `firstText == "and play some music"`, `secondText == "and play some music"` (expected "open Safari and play some music"). Reproduced with a fake microphone. Not yet confirmed on the real mic: manual checklist items 2 and 15.
Suspected cause: `SpeechInput.stop()` awaited the final words, then cleared `task`, `request` and `transcript`, all shared by every recording. A recording started during that wait got its words reset and its recognizer cancelled.
Status: fixed in 90aa607. Each recording keeps its own words. A recording started while the previous one is still finishing continues it (the first one returns "" and its words lead the second), and the controller keeps the buddy in listening for that handover.

### BUG-002: A second start while listening taps the microphone twice (AVAudioEngine crash)

- Severity: S2 (an app crash; reached only after BUG-001's state or a very fast triple-click on the mic)
- Flow / case: F01 / F01-E6
- Screen: S02
- Build: 6a263ed  Device: MacBook, macOS 26

Steps
1. Get the mic running with no listening state on screen (BUG-001's steps leave it like that).
2. Hold ⌃⌥ again.

Expected: one recording; the second start does nothing.
Actual: `SpeechInput.start()` had no guard, so it installs a second tap on the input bus. AVAudioEngine raises an uncaught exception for a second tap on a bus ("required condition is false: nullptr == Tap()"), and the app quits.
Evidence: `SpeechInputTests.startingTwiceKeepsOneRecording` failed on 6a263ed: the fake mic recorded a second recording while the first one's audio was still running (`secondTap` true, 2 recordings). The crash itself was not triggered on the real mic; that part is AVAudioEngine's documented behaviour.
Status: fixed in 90aa607. `start()` returns at once while already listening. Also, if the audio engine fails to start, the tap is now removed, so a failed start can't leave one behind.

### BUG-003: Long reply sentences are cut off in the cursor bubble while still being spoken

- Severity: S3 (the full reply is in the chat window)
- Flow / case: F01 / F01-E8
- Screen: S02
- Build: 90aa607  Device: rendered at 2x by the DEBUG preview renderer

Steps
1. `swift build && .build/debug/Companion --render-previews /tmp/zoobie-previews`
2. Open `buddy-long.png` (a spoken caption of ~310 characters).

Expected: the whole sentence readable while ZOOBIE says it.
Actual: the bubble stops after 4 lines with "…": about 170 of 310 characters show, and the rest is spoken but never shown beside the cursor.
Evidence: `buddy-long.png` from the renderer (the `buddy-long` preview state in `Buddy.swift`); cause `CaptionBubble` `.lineLimit(4)`.
Suspected cause / fix options: raise the limit (the bubble frame has room for about 7 lines), or split long sentences into caption chunks timed with the speech.
Status: open

## To check (not reproduced)

- **Icon-only buttons may have no spoken names.** The mic, send (`arrow.up`), stop and eye buttons set `.help` but no `.accessibilityLabel`; VoiceOver may read "Up Arrow" for send. Manual checklist item 13.
- **A missed ⌃⌥ release could leave the mic on.** macOS pauses an event tap it thinks is stuck, and secure input (a focused password field) hides key events from taps. If the release falls in that gap, `ModifierHoldMonitor` stays active until the next ⌃⌥ press. Manual checklist item 6.
- **Holding ⌃⌥ while an approval waits does nothing, with no feedback.** By design (`beginVoice` won't clobber the pending action), but the buddy shows nothing. Check whether it's confusing.
- **⌃⌥ held over 0.22 s before a shortcut key starts push-to-talk.** The shortcut still works, but the mic opens briefly. Clicky has the same delay trade-off.
