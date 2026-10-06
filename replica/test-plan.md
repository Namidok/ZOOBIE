# Test plan: ZOOBIE (Clicky features)

Build: 6a263ed + push-to-talk fixes  Date: 2026-10-06  Env: local, macOS 26 (Darwin 25.6), Command Line Tools only

ZOOBIE is a native macOS menu-bar app, not a web app, so Playwright does not apply. Instead:

- **unit**: Swift Testing with fakes for the microphone and keyboard (`Tests/CompanionTests/PushToTalkTests.swift`). Run: `scripts/test.sh`.
- **render**: the app's DEBUG preview renderer, which draws the cursor buddy and its reply bubble to PNGs without opening a window: `swift build && .build/debug/Companion --render-previews <dir>`.
- **manual**: needs a real microphone, global hotkeys, permissions or the live model. Checklist at the bottom.

The recon map lists one flow (F01). F02 and F03 come from the feature matrix rows built on 2026-10-04 (chat window, click-to-talk mic).

Not applicable to this app: second user's data and expired sessions (single local user, no accounts), payments, two tabs, back button and refresh (no browser), mobile width (desktop only), time zones (no dates in these flows).

## F01 Ask out loud (hold ⌃⌥, talk, release)

| case | type | steps | expected | auto | result |
| --- | --- | --- | --- | --- | --- |
| F01-H1 | happy | hold ⌃⌥, say "what time is it", release | waveform beside the cursor while holding, the question in a bubble, spinner, reply bubble + voice, bubble fades ~1.6 s after | unit (hold + speech) / manual (end to end) | unit pass; manual pending |
| F01-E1 | edge: nothing said | hold ⌃⌥ 1 s in silence, release | buddy back to idle, nothing sent | unit | pass |
| F01-E2 | edge: accents and emoji | say "Wie spät ist es in Zürich?" | text kept whole, bubble draws it | unit + render | pass |
| F01-E3 | edge: quick tap | tap ⌃⌥ for < 0.22 s | nothing happens | unit | pass |
| F01-E4 | edge: shortcut | ⌃⌥→ (any ⌃⌥ shortcut) | shortcut works, no push-to-talk | unit | pass |
| F01-E5 | edge: talk again at once | hold, say "open Safari", release, within 0.4 s hold again, say "and play some music", release | one question: "open Safari and play some music"; listening stays on screen in between | unit | **fail → fixed (BUG-001)** |
| F01-E6 | edge: second start while listening | a second start reaches the mic while it is already recording | one recording, the mic tapped once | unit | **fail → fixed (BUG-002)** |
| F01-E7 | edge: talk mid-reply | hold ⌃⌥ while ZOOBIE is speaking | voice stops at once, new question taken | manual | pending |
| F01-E8 | edge: very long reply sentence | a reply sentence of ~300 characters | the whole sentence readable while it is spoken | render | **fail (BUG-003)** |
| F01-E9 | edge: screen edge | cursor in the bottom-right corner while ZOOBIE replies | bubble flips left/up and stays on screen | render (flipped state) / manual | render pass; manual pending |
| F01-E10 | edge: Caps Lock / fn | Caps Lock on, hold ⌃⌥ | push-to-talk still works | unit | pass |
| F01-E11 | edge: extra modifier | hold ⌃⌥⌘ | not push-to-talk | unit | pass |
| F01-E12 | edge: two monitors | move the cursor to the second display, ask | buddy follows; bubble on that display | manual | pending |
| F01-E13 | edge: full-screen app | ask while a full-screen app is in front | buddy and bubble visible over it | manual | pending |
| F01-E14 | edge: password field focused | focus a password field, hold ⌃⌥, release | nothing, or a normal question; never a mic stuck on | manual | pending |
| F01-E15 | edge: bubble turned off | Settings › Show replies next to the cursor off, ask | no bubble; reply in the chat window | manual | pending |
| F01-E16 | edge: offline | Wi-Fi off, local brain, ask | answers (local); with Claude as brain, a clear error or local fallback | manual | pending |
| F01-N1 | negative: no mic / speech permission | deny Microphone or Speech Recognition, hold ⌃⌥ | notice naming the exact System Settings pane | manual | pending |
| F01-N2 | negative: cancel | hold ⌃⌥, talk, press Space (⌃⌥Space) | recording dropped, nothing sent, chat opens | unit (hold + speech) | pass |
| F01-N3 | negative: no Accessibility | launch without it, hold ⌃⌥; then grant it | nothing at first + setup note; works after granting, no relaunch | manual | pending |
| F01-N4 | negative: Ollama not running | quit Ollama, ask | error saying the local brain is not running | manual | pending |

## F02 Type in the chat window (⌃⌥Space)

| case | type | steps | expected | auto | result |
| --- | --- | --- | --- | --- | --- |
| F02-H1 | happy | ⌃⌥Space, type "hi", Return | chat opens focused, message appears, reply streams | manual | pending |
| F02-E1 | edge: empty | Return on an empty or spaces-only field | Send disabled, nothing sent | manual (code reading agrees) | pending |
| F02-E2 | edge: double submit | press Return twice fast / double-click Send | one request | manual (code reading agrees: the field clears synchronously) | pending |
| F02-E3 | edge: very long input | paste 5,000 characters, send | field grows to 6 lines then scrolls; message wraps in the conversation | manual | pending |
| F02-E4 | edge: new line | Shift-Return | new line, not sent | manual | pending |
| F02-E5 | edge: toggle | ⌃⌥Space while the chat has the keyboard | chat closes | manual | pending |
| F02-E6 | edge: Esc order | Esc with settings open / while working / idle | settings close, then work stops, then the window closes | manual | pending |
| F02-E7 | edge: keyboard only | Tab through mic, eye, field, send | every control reachable and visibly focused | manual | pending |
| F02-E8 | edge: VoiceOver | VoiceOver on, move across the composer | mic, send, stop and eye buttons have spoken names | manual | pending |
| F02-N1 | negative: approval pending | an action waits for OK, try to type | field disabled, placeholder "Waiting for your OK…" | manual | pending |

## F03 Click-to-talk mic button

| case | type | steps | expected | auto | result |
| --- | --- | --- | --- | --- | --- |
| F03-H1 | happy | click the mic, speak, click again | waveform icon while listening; question sent | manual | pending |
| F03-E1 | edge: double-click | double-click the mic while listening | behaves like one click; no words lost; mic not left on | unit (same path as F01-E5) | **fail → fixed (BUG-001)** |
| F03-E2 | edge: mic then hotkey | click the mic, then hold and release ⌃⌥ | one recording; sent on release | manual | pending |
| F03-N1 | negative: mic denied | deny Microphone, click the mic | notice naming the pane; button back to idle | manual | pending |

## Totals

35 cases. 13 have an automated check (12 new unit tests, 3 rendered bubble states). On the original code 4 of them failed (F01-E5, F01-E6, F01-E8, F03-E1). After the fixes 12 of 13 pass; F01-E8 (BUG-003, S3) is still open. 22 cases are manual only, and F01-H1 and F01-E9 also need an end-to-end check: all waiting for you.

## Manual checklist (needs you at the Mac)

Build and launch: `scripts/build-app.sh` then open the app. Answer each line with pass/fail and a note.

1. F01-H1: hold ⌃⌥, ask "what time is it", release.
2. F01-E5 (confirms the BUG-001 fix on the real mic): hold, "open Safari", release, hold again at once, "and play some music", release. Expect one question with both halves.
3. F01-E7: ask something long, hold ⌃⌥ while it speaks.
4. F01-E9: ask with the cursor in the bottom-right corner.
5. F01-E12 / E13: second display; a full-screen app in front.
6. F01-E14: focus a password field (e.g. a Safari login), hold ⌃⌥ 2 s, release. Is the orange mic dot off afterwards?
7. F01-E15: turn the cursor bubble off in Settings, ask.
8. F01-E16: Wi-Fi off, ask.
9. F01-N1: System Settings › Privacy & Security › Microphone, turn ZOOBIE off, hold ⌃⌥. (Turn it back on after.)
10. F01-N3: only if convenient: remove ZOOBIE from Accessibility, relaunch, hold ⌃⌥, then grant it again.
11. F01-N4: quit Ollama, ask.
12. F02-H1 to E6: ⌃⌥Space, type, Return; empty Return; double Return; paste a long text; Shift-Return; ⌃⌥Space to close; Esc.
13. F02-E7 / E8: Tab through the composer; then VoiceOver (⌘F5) over the mic, eye, send and stop buttons.
14. F02-N1: ask for something risky ("delete ~/Desktop/test.txt") so an approval appears, try to type.
15. F03-H1, E1, E2, N1: mic click, speak, click; double-click the mic while listening (confirms BUG-001 on the real mic); mic then ⌃⌥; mic with Microphone denied.
