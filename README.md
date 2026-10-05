# ZOOBIE

A private, local-first desktop companion for macOS in the spirit of FRIDAY. It lives at your cursor, sees your screen, talks with a natural on-device voice, and does what you ask on your Mac — opening apps, controlling music, clicking, typing, running commands — asking first only for risky actions. Everything runs on-device: models via [Ollama](https://ollama.com), OCR via Apple Vision, speech recognition and a neural voice (Kokoro) locally.

## Use

ZOOBIE lives next to your cursor (a small pixel arrow) and in a **chat window that drops down from the notch**: ZOOBIE and its four specialists (Scrapeman, KMan, Zoobs, Adolf — avatars in `img/`) in a sidebar, the conversation beside it. Hover the notch to open it; it also drops down by itself while ZOOBIE works on a request. Ask it anything, or tell it to do something — it answers questions and **performs actions itself**.

| Input | What happens |
|---|---|
| **Hold ⌃⌥**, speak, release | A waveform appears by the pointer while it listens, then a spinner, then the reply in a bubble next to your cursor as it answers out loud. Requests like "resume Spotify" or "open a new Safari tab" just get done. |
| **⌃⌥Space** or **click the menu bar icon** | Opens the chat window, ready to type (press again to close). The red mic button there works like holding ⌃⌥. |
| **Esc** | Stops an approval, then talking or the current task, then closes the window. |

**Agents** — hand off longer jobs ("agent: research the best 4K monitors under $500", or open a specialist in the sidebar and give it a task). Each works in the background with web search, files, shell and AppleScript — never your screen, mouse or keyboard — while you keep working. Its conversation shows the progress and the result; risky steps ask for approval there (the window comes up by itself); when one finishes ZOOBIE tells you, and the report is saved to `~/Documents/ZOOBIE/`. Agents run on Claude while your API key has credits, and switch to the local model by themselves when it doesn't (no credits, offline, overloaded) or when there's no key — with their own free web search (DuckDuckGo) and page reading. Local agents pause while you're talking to ZOOBIE so its replies stay fast; their research is shallower than Claude's.

**Approvals** (Settings › *Ask before acting*): harmless actions just happen — opening apps, play/pause, clicking, typing, read-only commands like `ls` or `git status`. Anything that deletes, overwrites, installs, sends, quits or changes the system asks first; destructive ones are flagged **CAUTION**.

Code and commands are never read aloud — they appear in the chat window with a copy button (it opens by itself when a spoken answer includes code). The first launch walks you through setup (permissions, voice, brain) in a short onboarding window.

## Brain

ZOOBIE has two brains (chat window › gear › **Brain**):

- **Claude** (default, recommended) — the model behind products like Clicky. It sees a screenshot of your screen, points at any button or icon with pixel accuracy, and acts reliably. Needs a key from [console.anthropic.com](https://console.anthropic.com): add it during onboarding or in Settings (stored in your Keychain). Uses Claude Opus 5.5 at low effort for quick voice replies; switch to Sonnet 5.5 or Haiku 4.5 in Settings for lower cost. Agents run at medium effort. Screenshots and questions are sent to Anthropic.
- **Local only** — Ollama on your Mac; nothing leaves the machine. Less capable (reads the screen as OCR text, can only click things with visible text). Also the automatic fallback when Claude is unreachable.

## Voice

ZOOBIE speaks with **Kokoro**, a neural voice that runs entirely on your Mac (default: *Heart*, a warm American female voice). Pick another in Settings › **Voice** — each choice plays a preview. If the neural voice isn't installed or running, it falls back to Apple's *Moira* (Irish).

```bash
scripts/setup-voice.sh    # one-time: Python venv + ~350 MB model in ~/Library/Application Support/Companion/voice
```

## Setup

Requirements: Apple Silicon, macOS 14+, Command Line Tools (Xcode optional), Ollama running.

```bash
ollama pull qwen2.5-coder:7b          # default chat + agent model
ollama pull qwen2.5vl:3b              # optional: lets it understand images/diagrams, not just text
scripts/build-app.sh --install --open # builds build/ZOOBIE.app, copies to /Applications, launches
```

On first launch an onboarding window walks through these (Settings in the chat window shows their status later):

| Permission | Used for |
|---|---|
| Accessibility | hold-⌃⌥ detection, window titles, clicking/typing/media keys for actions |
| Screen Recording | reading the screen (relaunch after granting) |
| Microphone + Speech Recognition | push-to-talk (transcription is forced on-device) |
| Automation (asked per app) | controlling apps like Spotify or Safari via AppleScript |

If on-device speech isn't available, enable Dictation once in System Settings › Keyboard to download the model.

> **Keep permissions across rebuilds:** run `scripts/make-signing-identity.sh` once. It creates a local self-signed "Companion Local Signing" certificate that `build-app.sh` then uses; the first build asks for your login password (choose **Always Allow**). Without it, every rebuild looks like a new app to macOS and silently loses Accessibility / Screen Recording.

## Configure

Most settings are behind the gear in the chat window. Everything lives in `~/Library/Application Support/Companion/config.json`:

| Key | Default | |
|---|---|---|
| `brain` | `claude` | `claude` or `local` |
| `claudeModel` / `claudeEffort` | `claude-opus-5-5` / `low` | Claude model and effort (`low`…`max`) |
| `chatModel` | `qwen2.5-coder:7b` | the local model (must support tools); also the offline fallback |
| `voice` / `speechSpeed` | `af_heart` / `1.05` | a Kokoro voice id, or `system:Moira` for an Apple voice |
| `approvalPolicy` | `risky` | `risky`, `always` or `never` |
| `visionModel` | auto | first installed model with the vision capability |
| `visionMode` | `auto` | `auto` = use the vision model only when OCR finds little text or the question is visual; `always`; `never` |
| `speakReplies` / `speakTypedReplies` | `true` / `false` | speak answers to voice / typed questions (captions show either way) |
| `agentWorkingDirectory` | `~` | where agent commands run |
| `agentMaxSteps` / `commandTimeout` | `12` / `60` | per-task step cap, per-command seconds |
| `numCtx` / `keepAlive` | `8192` / `-1m` | context window; how long Ollama keeps the model loaded (`-1m` = always, so replies stay fast; `30m` frees ~5 GB when idle) |

## Speed (local brain)

On Apple Silicon a 7B model *reads* only ~170 tokens a second, so what ZOOBIE sends matters more than the model:

- **Pre-reading.** On launch and the moment you press ⌃⌥ (while you're still talking), the model reads its instructions and recent history in advance; your request then only adds the new question (~0.2 s instead of ~15 s).
- **Screen only when asked.** Screen text goes to the local model only when the request is about it ("this error", "what's on my screen"); a screenful costs it 5–15 s to read.
- **Talks first.** "On it." plays while the model is still writing the action, and long answers start on their first clause.

Measure it with `swift run -c release Bench [model …]` (14 everyday requests, nothing is executed), and see live timings with `log show --last 10m --predicate 'subsystem == "local.companion.agent"' | grep latency`. On an M4 with qwen2.5-coder:7b, ZOOBIE starts talking ~0.8–1.4 s after you ask and acts within ~1.5–3.5 s; questions about the screen take ~10–15 s.

## Privacy

- With the **Local only** brain, the only network traffic is to `ollamaURL` (default `127.0.0.1:11434`). With the **Claude** brain, your question, a downscaled screenshot and the screen text go to Anthropic's API for each request.
- The Claude API key lives in the macOS Keychain, never in config.json or logs.
- Screenshots and audio stay in memory and are never written to disk; Companion excludes its own windows from captures.
- Speech recognition sets `requiresOnDeviceRecognition`; if on-device isn't available it fails rather than falling back to Apple's servers.
- Conversation history lives in memory until you clear it or quit.
- Actions that delete, overwrite, install, send, quit or change system settings always wait for your approval (unless you choose *Never* under *Ask before acting*). Tool calls with made-up placeholder paths are rejected before they can run.
- The neural voice runs as a local process on 127.0.0.1 and is stopped when Companion quits.

## Develop

```
Sources/CompanionCore/   Foundation-only, unit-tested
  Config.swift             config file + JSON value type
  Ollama.swift             streaming /api/chat client, model capabilities, warm-up
  Prompts.swift            assistant (answer-or-act) + vision system prompts
  ScreenContext.swift      OCR lines → <screen> prompt block (cursor-prioritised), streaming narration + [POINT] tags, vision routing
  Agent.swift              tools, approval policy, fallback tool-call parser, executor, local answer-or-act loop
  Claude.swift             Claude Messages API client (raw HTTP + SSE), the answer-or-act loop, and worker agents (web search/fetch)
  AgentRuns.swift          persisted agent jobs and Markdown reports
Sources/Companion/       the app
  main.swift               app delegate, status item, hotkey wiring
  CompanionController.swift orchestration
  ChatWindow.swift         the chat window: sidebar (ZOOBIE + specialists), conversations, approvals, composer, settings
  Agents.swift             background agent manager (concurrent Claude workers, approvals, reports)
  Onboarding.swift         first-run setup window
  MenuBarPanel.swift       the Settings view
  DesignSystem.swift       colors, buttons, segmented control, brand mark, menu bar icon
  Capture.swift            ScreenCaptureKit + Vision OCR, permissions
  Input.swift              ⌃⌥Space hotkey, hold-⌃⌥ monitor, speech in
  APIKeyStore.swift        Claude API key in the Keychain
  Voice.swift              Kokoro voice server + sentence-synced narrator (Apple voice fallback)
  MacControl.swift         media keys, clicks, shortcuts, typing
  Buddy.swift              cursor pointer: follows the cursor, flies to and points at things
  Overlay.swift            on-screen highlights
  Panel.swift              message building blocks: step cards, Markdown, copyable code
```

Diagnostics — every request, action and result is logged locally:

```bash
/usr/bin/log show --last 30m --style compact --predicate 'subsystem == "local.companion.agent"'
```

```bash
scripts/test.sh                                               # unit tests
swift scripts/make-icon.swift                                 # regenerate Resources/AppIcon.icns
COMPANION_LIVE=1 scripts/test.sh --filter LiveOllamaTests     # against your local Ollama
swift build && .build/debug/Companion                         # quick run (voice needs the .app bundle)
```

Small local models often write tool calls into their reply text (qwen2.5-coder emits bare JSON) and sometimes narrate a step without calling it. `ToolCallParser` recovers the calls and the agent loop nudges the model when it announces an action it didn't take — see the live tests.
