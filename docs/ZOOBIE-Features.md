# ZOOBIE — What's Built (v0.3, 1 Oct 2026)

ZOOBIE is a FRIDAY-style AI assistant for macOS. It lives in a chat window and next to your cursor, sees your screen, talks with you, points at things, does things on your Mac, and runs background agents for longer jobs. Claude is the brain; a local Ollama model is the private/offline fallback.

Repo: **github.com/Namidok/ZOOBIE** (private) · App: `/Applications/ZOOBIE.app` · Stack: native Swift 6 / SwiftUI + AppKit, SwiftPM (no Xcode needed)

---

## 1. How you use it

| Input | What happens |
|---|---|
| **Hold ⌃⌥ (Control + Option)**, speak, release | Push-to-talk. The pointer shows a waveform, then a spinner, then the reply in a bubble next to the cursor while ZOOBIE answers out loud. |
| **⌃⌥Space** / **menu-bar icon** | Opens (or closes) the chat window, ready to type. |
| **Esc** | Stops an approval, then talking / the current task, then closes the window. |

ZOOBIE decides by itself whether you asked a **question** (it answers) or asked it to **do** something (it does it). No prefix needed.

---

## 2. The chat window (replaced the notch on 2026-10-04)

A pixel-art window that drops down from the notch, in the style of Hey Clicky: a sidebar with ZOOBIE and the four specialists (live status, search, new chat, your profile, settings) and the conversation beside it (bubbles, step cards, copyable code, "Working on it · 7s", approval cards, a big red mic button). Specialists' chats show their tasks as exchanges with collapsible progress messages and the report. The section below describes the retired notch UI.

Design: **pixel** — the specialists' pixel-art avatars as a UI: deep navy and slate surfaces, hologram-cyan glow, dithered checker textures, notched pixel frames, an 8-bit arrow pointer and Jersey 10 pixel titles (palette sampled from `img/`, tokens in `replica/design/tokens.json`, 0 WCAG AA contrast failures); replies appear in a bubble next to the cursor, Clicky-style.

- A black shape that blends into the camera notch (Macs without a notch get a matching pill at the top of the screen). Built using the same window technique as the open-source app Boring Notch: a borderless panel above the menu bar, sized from the real notch geometry.
- **Live activity "wings"** on both sides of the camera: waveform (listening), spinner (thinking), animated bars (speaking), a running-agents counter, an approval hand when something needs your OK.
- **Drops out below the notch:** spoken captions, the typed-input field, code blocks with Copy buttons, approval cards, error notices, setup reminders, "agent finished" toasts.
- **Expanded tabs (on hover):**
  - **Assistant** — type a request, see the latest question and answer (formatted, code copyable), toggle whether the screen is included, open full history, stop the current task.
  - **Agents** — the four specialist cards (avatar, name, live status, Talk); open one to assign a task, follow its queue and reports, read its notebook, or forget its memory.
  - **Settings** — brain, model, API key, voice, speaking options, approval policy, permissions (with Grant / Reset buttons), history, quit.
- Clicks pass through everywhere outside the shape, so it never blocks the apps underneath. It collapses when the mouse leaves (or on an outside click if you were typing).

## 3. The cursor pointer

- A small glowing blue pointer trails your mouse.
- When ZOOBIE mentions something on screen, the pointer **flies along an arc to it** and a glowing outline highlights it — in sync with the sentence being spoken. Step-by-step answers walk through several elements in order.
- It works for text (by OCR id) and for icons/buttons without text (by pixel coordinates from Claude's vision).
- Option: show the pointer only while ZOOBIE is active.

## 4. Seeing the screen

- On each request ZOOBIE captures the display under your cursor (ScreenCaptureKit), reads all text with Apple's on-device OCR (Vision), and notes the frontmost app and window title.
- With the Claude brain, a downscaled screenshot (1280 px wide) plus the OCR text is sent so Claude truly *sees* the screen. With the local brain, only OCR text is used.
- ZOOBIE's own windows are excluded from captures. Screenshots stay in memory and are never written to disk.
- `read_screen` lets ZOOBIE re-check the screen after it acts (e.g. confirm a click worked).

## 5. The brain

| Brain | What it is | When |
|---|---|---|
| **Claude** (default) | Claude Opus 5.5 (switchable to Sonnet 5.5 or Haiku 4.5) via the Anthropic Messages API, streamed. Low effort for snappy voice replies; agents run at medium effort. Server-side refusal fallback enabled. Prompt caching on the system prompt + tools. | Best quality: vision, precise pointing, reliable actions, web research. |
| **Local only** | Ollama (`qwen2.5-coder:7b` by default), fully private. Optional local vision model (e.g. `qwen2.5vl`) for image questions. | Private mode, and automatic fallback when Claude is unreachable. |

- API key is stored in the **macOS Keychain** (never in files or logs). Paste it in onboarding or Settings.
- Persona: FRIDAY-style — crisp, capable, lightly witty — with Clicky's proven voice habits: writes for the ear, 1–2 sentences by default, never reads code aloud, points eagerly, no dead-end questions.
- Conversation memory: the last 8 exchanges are remembered within a session (in memory only).

## 6. Doing things on your Mac (tools)

| Tool | What it does |
|---|---|
| `open_app` | Launch or focus any app |
| `run_applescript` | Control scriptable apps: Spotify, Music, Safari, Finder, Mail, system volume… |
| `media_control` | Play/pause, next, previous, volume up/down, mute — works with any player |
| `click` | Click something on screen by OCR id, visible text, or pixel coordinates (pointer flies there first) |
| `type_text` | Type into the focused field |
| `press_keys` | Press shortcuts like ⌘T, ⌘⇧N, Return, arrows |
| `read_screen` | Re-capture the screen to check results |
| `run_shell` | Run terminal commands (non-interactive, 60 s timeout, no sudo) |
| `read_file` / `write_file` / `list_directory` | File work |
| `open_url` | Open a URL or file in its default app |
| `web_search` / `web_fetch` | Anthropic server-side web research (Claude brain) |
| `delegate` / `talk_to` | Hand a job to a specialist / talk to one directly |
| `set_timer` · `create_reminder` · `list_events` · `create_event` | Timers, Reminders, Calendar |

### Approvals (safety)
- **Default "Risky only":** harmless actions run immediately — opening apps, media keys, clicking, typing, look-only commands (`ls`, `git status`, `cat`…). Anything that deletes, overwrites, installs, sends, quits apps or changes the system shows an approval card in the chat window: **Run / Skip / Stop**. Destructive ones get a red **CAUTION** badge.
- Other modes: **Always ask** / **Never ask** (Settings).
- Commands containing made-up placeholder paths (e.g. `/path/to/your/project`) are rejected before they can run.
- Readable explanations when macOS blocks something (e.g. "allow ZOOBIE under Privacy & Security › Automation").

## 7. The four specialists (persistent background agents)

| Specialist | Role | Tools |
|---|---|---|
| **Job Hunter** | Job & internship search, application tracking, tailored CVs and cover letters. Methodical; structured Markdown. | web, files, shell, notebook |
| **Dev Mentor** | Senior dev & AI/ML teaching assistant: Python/FastAPI, ML, assignments. Analytical, teaches the why. | web, files, shell, notebook |
| **Scheduler** | Calendar, reminders, timers, daily admin. Efficient, proactive secretary. | timers, Reminders, Calendar, AppleScript, web, notebook |
| **German Tutor** | Grammar, vocabulary, conversational practice in German + English. Patient, structured. | web, files, notebook |

- **Routing:** `agent: …` always goes to the right specialist; ZOOBIE also delegates long jobs on its own. Quick things (a timer, one reminder, a calendar check) ZOOBIE does instantly itself.
- **Persistent:** each specialist keeps its own **notebook** (long-term memory it maintains: application tracker, your German level, preferences…) and **conversation thread**, stored as text in `~/Library/Application Support/Companion/agents/<id>/` — they remember you across days.
- **Task queue:** each specialist works through its tasks one at a time; all four work in parallel. Live progress and approvals in the specialist's chat, spoken summary + Markdown report in `~/Documents/ZOOBIE/` when done.
- **Talk to a specialist:** "let's practice German" (or the Talk button) switches the conversation to that specialist; say "back to ZOOBIE" to return. Their row lights up in the sidebar while you're talking.
- **German practice:** German sentences are spoken in a German voice (Anna), English in the main voice; optional German speech input ("I'll speak German" toggle).
- **Background safety:** specialists never touch your screen, mouse or keyboard while working in the background.
- **Names & avatars:** set names in `config.json` → `"agentNames": {"jobs": "…", "mentor": "…", "schedule": "…", "german": "…"}`; drop images at `~/Library/Application Support/Companion/avatars/<jobs|mentor|schedule|german>.png`.

## 7b. Timers, reminders, calendar

- `set_timer` / `list_timers` / `cancel_timer` — countdown shown in the chat window's sidebar, chime + spoken announcement when done, survives restarts.
- `create_reminder` (Apple Reminders, with due date/time), `list_events` and `create_event` (Apple Calendar) — dates are handled structurally, so they work regardless of system language.

## 8. Voice

- **Speech-to-text:** Apple on-device speech recognition (forced on-device; never sent to Apple's servers). Live partial transcript shown as you talk.
- **Text-to-speech:** **Kokoro** neural voice running locally (default *Heart*, American female; also Emma, Isabella, Alice, Lily, Bella, George), fallback to Apple's *Moira* (Irish). Speaks sentence by sentence while the answer is still streaming (~0.3–0.5 s to first audio). Code and commands are never read aloud.
- Options: speak answers to voice questions (on), speak answers to typed questions (off), voice preview, speech speed.
- The local voice server shuts down with the app (no leftover background process).

## 9. Onboarding & settings

- **First-launch setup window:** welcome → Accessibility → Screen Recording (survives the macOS "Quit & Reopen") → Microphone & Speech → Brain (paste Claude key or choose local) → "Try it". Each permission step detects the grant live and auto-continues.
- **Permissions persistence:** the app is signed with a stable local certificate ("Companion Local Signing"), so permissions survive rebuilds. A **Reset** button clears a stuck permission if macOS ever holds a stale entry.
- Copy/paste (⌘V, ⌘C, ⌘X, ⌘A, ⌘Z) works in all ZOOBIE text fields.
- Settings file: `~/Library/Application Support/Companion/config.json` (brain, models, effort, voice, speed, approval policy, working directory, step limits, timeouts…).

## 10. Privacy & security

- Claude brain: your question, a downscaled screenshot and screen text go to Anthropic per request. Local brain: nothing leaves the Mac.
- Screenshots and audio are never stored. Conversation lives in memory only. API key in Keychain.
- Risky actions always need approval (unless you choose "Never ask").
- Local diagnostics log (no secrets): `/usr/bin/log show --last 30m --predicate 'subsystem == "local.companion.agent"'`.

## 11. Under the hood

```
Sources/CompanionCore/   (pure logic, unit-tested)
  Claude.swift        Claude Messages API client (raw HTTP + SSE streaming), answer-or-act loop, worker agents
  Agent.swift         tool definitions, approval policy, fallback tool-call parser, executor, local loop
  AgentRuns.swift     persisted agent jobs + Markdown reports
  Ollama.swift        local model client
  Prompts.swift       assistant / worker / vision prompts
  ScreenContext.swift OCR → screen block, streaming narration + [POINT] parsing, vision routing
  Config.swift        settings
Sources/Companion/   (the app)
  Notch.swift, Agents.swift, CompanionController.swift, Buddy.swift, Overlay.swift, Voice.swift,
  Input.swift, Capture.swift, MacControl.swift, Onboarding.swift, MenuBarPanel.swift (Settings),
  DesignSystem.swift, APIKeyStore.swift, Panel.swift (history), main.swift
scripts/  build-app.sh · test.sh · setup-voice.sh · make-signing-identity.sh · make-icon.swift
```

- **Tests:** 44 automated tests (parsing, narration streaming, approval policy, tool parsing, agent persistence, Claude wire format and stream parsing, shell execution) + opt-in live tests against Ollama.
- **Build:** `scripts/build-app.sh --install --open` → signed `/Applications/ZOOBIE.app`.

## 12. Honest status

- ✅ Built, compiles cleanly, all automated tests pass, live-tested against the local model (answers, pointing tags, acting instead of explaining, multi-step file tasks).
- ⚠️ Not yet verified end-to-end on your Mac with the Claude key: the notch's look/animations, hover behaviour, real actions (Spotify, clicks), agents' web research, permission persistence after a rebuild.
- ✅ Added in v0.3: the four persistent specialists with notebooks and threads, timers, Reminders and Calendar, German voice switching, amber design.
- ❌ Not built yet: scheduled/recurring agents (daily internship scan), pomodoro cycles, a precise code-editing tool and "replace Claude CLI" coding mode, browser automation for forms with a saved profile, wake word ("Hey ZOOBIE"), long-term memory for ZOOBIE itself (specialists have it).
