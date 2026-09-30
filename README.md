# Companion

A private, local-first desktop companion for macOS in the spirit of FRIDAY. It lives at your cursor, sees your screen, talks with a natural on-device voice, and does what you ask on your Mac — opening apps, controlling music, clicking, typing, running commands — asking first only for risky actions. Everything runs on-device: models via [Ollama](https://ollama.com), OCR via Apple Vision, speech recognition and a neural voice (Kokoro) locally.

## Use

There's no window to manage — Companion lives at your cursor. Ask it anything, or tell it to do something: it answers questions and **performs actions itself** (no special prefix).

| Input | What happens |
|---|---|
| **Hold ⌃⌥**, speak, release | A waveform shows it's listening. It reads the screen under the cursor, then answers out loud with live captions — or does what you asked ("resume Spotify", "open a new Safari tab", "what's using port 3000?"). When it mentions something on screen, the buddy flies there and outlines it. |
| **⌃⌥Space** | A one-line input bubble at the cursor, for typing instead of talking. |
| **Esc** | Stops talking / the current task; otherwise dismisses the card. |

**What it can do on your Mac:** open apps, control scriptable apps with AppleScript (Spotify, Music, Safari, Finder, Mail, system volume…), press media keys, click things on screen, type, press shortcuts, re-read the screen, run shell commands, read/write files, open URLs.

**Approvals** (menu › *Ask before acting*): by default harmless actions just happen — opening apps, play/pause, clicking, typing, read-only commands like `ls` or `git status`. Anything that deletes, overwrites, installs, sends, quits or changes the system shows a small card first: **↩ Run · ⌘S Skip · Esc Stop**; destructive ones are flagged **CAUTION**.

Code and commands are never read aloud — they appear in a card with a copy button. The full transcript (and every action's output) is under menu › **Show History**.

## Brain

Companion has two brains (menu › **Brain**):

- **Claude** (default, recommended) — the model behind products like Clicky. It sees a screenshot of your screen, points at any button or icon with pixel accuracy, and acts reliably. Needs a key from [console.anthropic.com](https://console.anthropic.com): menu › Brain › **Claude API Key…** (stored in your Keychain). Uses Claude Opus 5.5 at low effort for quick voice replies; switch to Sonnet 5.5 or Haiku 4.5 in the same menu for lower cost. Screenshots and questions are sent to Anthropic.
- **Local only** — Ollama on your Mac; nothing leaves the machine. Less capable (reads the screen as OCR text, can only click things with visible text). Also the automatic fallback when Claude is unreachable.

## Voice

Companion speaks with **Kokoro**, a neural voice that runs entirely on your Mac (default: *Emma*, British). Pick another under menu › **Voice** — each choice plays a preview. If the neural voice isn't installed or running, it falls back to Apple's *Moira* (Irish).

```bash
scripts/setup-voice.sh    # one-time: Python venv + ~350 MB model in ~/Library/Application Support/Companion/voice
```

## Setup

Requirements: Apple Silicon, macOS 14+, Command Line Tools (Xcode optional), Ollama running.

```bash
ollama pull qwen2.5-coder:7b          # default chat + agent model
ollama pull qwen2.5vl:3b              # optional: lets it understand images/diagrams, not just text
scripts/build-app.sh --install --open # builds build/Companion.app, copies to /Applications, launches
```

On first use macOS asks for permissions (menu bar icon › **Permissions** shows status and opens each pane):

| Permission | Used for |
|---|---|
| Accessibility | hold-⌃⌥ detection, window titles, clicking/typing/media keys for actions |
| Screen Recording | reading the screen (relaunch after granting) |
| Microphone + Speech Recognition | push-to-talk (transcription is forced on-device) |
| Automation (asked per app) | controlling apps like Spotify or Safari via AppleScript |

If on-device speech isn't available, enable Dictation once in System Settings › Keyboard to download the model.

> **Keep permissions across rebuilds:** run `scripts/make-signing-identity.sh` once. It creates a local self-signed "Companion Local Signing" certificate that `build-app.sh` then uses; the first build asks for your login password (choose **Always Allow**). Without it, every rebuild looks like a new app to macOS and silently loses Accessibility / Screen Recording.

## Configure

Menu bar icon › chat / agent / vision model, spoken-reply toggles, buddy visibility. Everything else lives in `~/Library/Application Support/Companion/config.json` (menu › **Edit config.json…**, then **Reload config**):

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
  Claude.swift             Claude Messages API client (raw HTTP + SSE) and the Claude answer-or-act loop
Sources/Companion/       the app
  main.swift               app delegate, menu bar, hotkey wiring
  CompanionController.swift orchestration
  Capture.swift            ScreenCaptureKit + Vision OCR, permissions
  Input.swift              ⌃⌥Space hotkey, hold-⌃⌥ monitor, speech in
  APIKeyStore.swift        Claude API key in the Keychain
  Voice.swift              Kokoro voice server + sentence-synced narrator (Apple voice fallback)
  MacControl.swift         media keys, clicks, shortcuts, typing
  Buddy.swift              cursor buddy: glyph, waveform, captions, pointing
  Overlay.swift            on-screen highlights + the cursor card (input, code, approvals)
  Panel.swift              history panel
```

Diagnostics — every request, action and result is logged locally:

```bash
log show --last 30m --style compact --predicate 'subsystem == "local.companion.agent"'
```

```bash
scripts/test.sh                                               # unit tests
COMPANION_LIVE=1 scripts/test.sh --filter LiveOllamaTests     # against your local Ollama
swift build && .build/debug/Companion                         # quick run (voice needs the .app bundle)
```

Small local models often write tool calls into their reply text (qwen2.5-coder emits bare JSON) and sometimes narrate a step without calling it. `ToolCallParser` recovers the calls and the agent loop nudges the model when it announces an action it didn't take — see the live tests.
