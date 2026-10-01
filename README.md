# ZOOBIE

A private, local-first desktop companion for macOS in the spirit of FRIDAY. It lives at your cursor, sees your screen, talks with a natural on-device voice, and does what you ask on your Mac — opening apps, controlling music, clicking, typing, running commands — asking first only for risky actions. Everything runs on-device: models via [Ollama](https://ollama.com), OCR via Apple Vision, speech recognition and a neural voice (Kokoro) locally.

## Use

ZOOBIE lives in your MacBook's **notch** (a matching pill at the top of the screen on Macs without one) and next to your cursor. Ask it anything, or tell it to do something — it answers questions and **performs actions itself**.

| Input | What happens |
|---|---|
| **Hold ⌃⌥**, speak, release | The notch shows a waveform while it listens, then a spinner, then live captions as it answers out loud. When it mentions something on screen, the cursor pointer flies there and outlines it. Requests like "resume Spotify" or "open a new Safari tab" just get done. |
| **⌃⌥Space** | A one-line input drops out of the notch for typing. |
| **Hover the notch** | It expands into **Assistant** (type, read the latest answer, copy code), **Agents** and **Settings**. |
| **Esc** | Stops talking / the current task, or closes the notch. |

**Agents** — hand off longer jobs ("start an agent to research the best 4K monitors under $500", or type it in the Agents tab). Each agent works in the background with web search, files, shell and AppleScript — never your screen, mouse or keyboard — while you keep working. The notch shows how many are running; risky steps ask for approval in the notch; when one finishes ZOOBIE tells you, and the report is saved to `~/Documents/ZOOBIE/`. Up to four run at once. Agents need the Claude brain.

**Approvals** (Settings › *Ask before acting*): harmless actions just happen — opening apps, play/pause, clicking, typing, read-only commands like `ls` or `git status`. Anything that deletes, overwrites, installs, sends, quits or changes the system asks first; destructive ones are flagged **CAUTION**.

Code and commands are never read aloud — they appear under the notch with a copy button. The first launch walks you through setup (permissions, voice, brain) in a short onboarding window.

## Brain

ZOOBIE has two brains (notch › Settings › **Brain**):

- **Claude** (default, recommended) — the model behind products like Clicky. It sees a screenshot of your screen, points at any button or icon with pixel accuracy, and acts reliably. Needs a key from [console.anthropic.com](https://console.anthropic.com): add it during onboarding or in Settings (stored in your Keychain). Uses Claude Opus 5.5 at low effort for quick voice replies; switch to Sonnet 5.5 or Haiku 4.5 in Settings for lower cost. Agents run at medium effort. Screenshots and questions are sent to Anthropic.
- **Local only** — Ollama on your Mac; nothing leaves the machine. Less capable (reads the screen as OCR text, can only click things with visible text). Also the automatic fallback when Claude is unreachable.

## Voice

ZOOBIE speaks with **Kokoro**, a neural voice that runs entirely on your Mac (default: *Emma*, British). Pick another in Settings › **Voice** — each choice plays a preview. If the neural voice isn't installed or running, it falls back to Apple's *Moira* (Irish).

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

On first launch an onboarding window walks through these (Settings in the notch shows their status later):

| Permission | Used for |
|---|---|
| Accessibility | hold-⌃⌥ detection, window titles, clicking/typing/media keys for actions |
| Screen Recording | reading the screen (relaunch after granting) |
| Microphone + Speech Recognition | push-to-talk (transcription is forced on-device) |
| Automation (asked per app) | controlling apps like Spotify or Safari via AppleScript |

If on-device speech isn't available, enable Dictation once in System Settings › Keyboard to download the model.

> **Keep permissions across rebuilds:** run `scripts/make-signing-identity.sh` once. It creates a local self-signed "Companion Local Signing" certificate that `build-app.sh` then uses; the first build asks for your login password (choose **Always Allow**). Without it, every rebuild looks like a new app to macOS and silently loses Accessibility / Screen Recording.

## Configure

Most settings are in the notch's **Settings** tab (also opened by clicking the menu bar icon). Everything lives in `~/Library/Application Support/Companion/config.json`:

| Key | Default | |
|---|---|---|
| `brain` | `claude` | `claude` or `local` |
| `claudeModel` / `claudeEffort` | `claude-opus-5-5` / `low` | Claude model and effort (`low`…`max`) |
| `chatModel` | `qwen2.5-coder:7b` | the local model (must support tools); also the offline fallback |
| `voice` / `speechSpeed` | `bf_emma` / `1.05` | a Kokoro voice id, or `system:Moira` for an Apple voice |
| `approvalPolicy` | `risky` | `risky`, `always` or `never` |
| `visionModel` | auto | first installed model with the vision capability |
| `visionMode` | `auto` | `auto` = use the vision model only when OCR finds little text or the question is visual; `always`; `never` |
| `speakReplies` / `speakTypedReplies` | `true` / `false` | speak answers to voice / typed questions (captions show either way) |
| `agentWorkingDirectory` | `~` | where agent commands run |
| `agentMaxSteps` / `commandTimeout` | `12` / `60` | per-task step cap, per-command seconds |
| `numCtx` / `keepAlive` | `8192` / `30m` | context window; how long Ollama keeps the model loaded |

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
  Notch.swift              the notch island: live activity, captions, cards, Assistant/Agents/Settings tabs
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
  Overlay.swift            on-screen highlights + the card views shown in the notch (input, code, approvals)
  Panel.swift              history panel
```

Diagnostics — every request, action and result is logged locally:

```bash
log show --last 30m --style compact --predicate 'subsystem == "local.companion.agent"'
```

```bash
scripts/test.sh                                               # unit tests
swift scripts/make-icon.swift                                 # regenerate Resources/AppIcon.icns
COMPANION_LIVE=1 scripts/test.sh --filter LiveOllamaTests     # against your local Ollama
swift build && .build/debug/Companion                         # quick run (voice needs the .app bundle)
```

Small local models often write tool calls into their reply text (qwen2.5-coder emits bare JSON) and sometimes narrate a step without calling it. `ToolCallParser` recovers the calls and the agent loop nudges the model when it announces an action it didn't take — see the live tests.
