import AppKit
import CompanionCore
import os

/// Local diagnostics: `log show --last 1h --predicate 'subsystem == "local.companion.agent"'`
private let log = Logger(subsystem: "local.companion.agent", category: "assistant")

struct DisplayMessage: Identifiable {
    enum Kind { case user, assistant, step, error, note }
    enum StepState: Equatable { case awaiting, running, done(String), skipped, stopped }

    let id = UUID()
    var kind: Kind
    var text: String
    var action: AgentAction? = nil
    var stepState: StepState? = nil
}

/// Orchestrates capture → OCR → local model → voice, captions, pointing and highlights. Every request
/// goes to one tool-using brain: it answers questions and performs actions (risky ones wait for
/// approval). The cursor buddy and a small card near the cursor are the UI; the full transcript lives
/// in an optional history panel. State lives only in memory.
@MainActor
final class CompanionController: ObservableObject {
    @Published private(set) var messages: [DisplayMessage] = [] {
        didSet { if messages.isEmpty != oldValue.isEmpty { historyPanel.setExpanded(!messages.isEmpty) } }
    }
    @Published var input = ""
    @Published var includeScreen = true
    @Published private(set) var isBusy = false
    @Published private(set) var screenSummary: String?
    @Published private(set) var pendingAction: AgentAction?
    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var config: CompanionConfig
    @Published private(set) var activeModel: String?
    @Published private(set) var focusToken = 0

    let buddy = BuddyOverlay()
    let voiceServer = VoiceServer()
    private let highlights = HighlightOverlay()
    private let narrator = Narrator()
    private let speechIn = SpeechInput()
    private lazy var card = CursorCard(controller: self)
    private lazy var historyPanel = FloatingPanel(controller: self)
    private var client: OllamaClient
    /// Prior turns without their screen blocks, so follow-ups stay cheap.
    private var history: [ChatMessage] = []
    private var snapshotTask: Task<Snapshot?, Never>?
    /// The latest screen reading, for resolving [POINT:id] tags and click targets.
    private var latestSnapshot: Snapshot?
    private var narrationToken = 0
    /// The current model turn's visible text and how many of its sentences are already queued.
    private var turnText = ""
    private var turnSpoken = 0
    private var workTask: Task<Void, Never>?
    private var generation = 0
    private var confirmation: CheckedContinuation<AgentDecision, Never>?
    private var voiceRequested = false
    private var agentTurnID: UUID?
    private var agentStepID: UUID?
    private var warnedAboutScreen = false

    init() {
        let config = CompanionConfig.load()
        self.config = config
        client = OllamaClient(baseURL: config.ollamaURL)
        buddy.showWhenIdle = config.showBuddy
        speechIn.onPartial = { [weak self] text in self?.buddy.setCaption(String(text.suffix(90)), style: .user) }
        speechIn.onLevel = { [weak self] level in self?.buddy.model.push(level: CGFloat(level)) }
        narrator.onStep = { [weak self] step in self?.present(step) }
        narrator.onFinish = { [weak self] in self?.narrationFinished() }
    }

    var visionModel: String? {
        guard config.visionMode != .never else { return nil }
        return config.visionModel ?? models.first(where: \.supportsVision)?.name
    }

    func start() {
        buddy.start()
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            flash("Hi! Hold ⌃⌥ and talk to me, or press ⌃⌥Space to type.", for: 7)
        }
        Task { await refreshModels(warmUp: true) }
        Task { await voiceServer.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkSetup(reportIfFine: false) }
    }

    /// Shows what's missing for Companion to act (Accessibility and Screen Recording).
    func checkSetup(reportIfFine: Bool) {
        let missing = [Permissions.Kind.accessibility, .screenRecording].filter { !$0.isGranted }
        log.info("setup check: missing \(missing.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        if !missing.isEmpty {
            card.show(.setup(missing), focus: false)
        } else if reportIfFine {
            flash("All set — I have the permissions I need.")
        }
    }

    func shutdown() {
        narrator.stop()
        voiceServer.stop()
    }

    // MARK: Config & models

    func update(_ change: (inout CompanionConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        if next.ollamaURL != config.ollamaURL { client = OllamaClient(baseURL: next.ollamaURL) }
        config = next
        buddy.showWhenIdle = next.showBuddy
        try? next.save()
    }

    func reloadConfig() {
        let loaded = CompanionConfig.load()
        update { $0 = loaded }
        Task { await refreshModels(warmUp: true) }
    }

    func selectChatModel(_ name: String) {
        update { $0.chatModel = name }
        let client = self.client, keepAlive = config.keepAlive
        Task { await client.warmUp(model: name, keepAlive: keepAlive) }
    }

    /// Speaks a short sample so the user can hear a voice before keeping it.
    func previewVoice() {
        beginNarration(voiced: true, snapshot: nil)
        narrator.enqueue(NarrationStep(text: "Hi, I'm your companion. Just tell me what you need."))
        narrator.finishInput()
    }

    func refreshModels(warmUp: Bool) async {
        do {
            models = try await client.listModels()
        } catch {
            if warmUp { showNotice(error.localizedDescription) } else { note(error.localizedDescription) }
            return
        }
        if !isInstalled(config.chatModel), let fallback = models.first(where: \.supportsTools)?.name ?? models.first?.name {
            note("\(config.chatModel) isn't installed — using \(fallback).")
            update { $0.chatModel = fallback }
        }
        if warmUp { await client.warmUp(model: config.chatModel, keepAlive: config.keepAlive) }
    }

    private func isInstalled(_ name: String) -> Bool {
        let full = name.contains(":") ? name : name + ":latest"
        return models.contains { $0.name == name || $0.name == full }
    }

    private func options(for model: String) -> OllamaClient.Options {
        let thinks = models.first { $0.name == model }?.supportsThinking == true
        // Thinking adds seconds of latency on an 8B model; keep replies snappy.
        return OllamaClient.Options(numCtx: config.numCtx, temperature: 0.2, keepAlive: config.keepAlive, think: thinks ? false : nil)
    }

    // MARK: Surfaces

    /// ⌃⌥Space: a one-line input next to the cursor.
    func toggleInput() {
        if card.isVisible, card.content == .input {
            card.hide()
            return
        }
        beginSnapshot()
        card.show(.input, focus: true)
    }

    func dismissCard() {
        card.hide()
    }

    func showHistory() {
        if card.content == .input { card.hide() }
        if !historyPanel.isVisible { historyPanel.place(near: NSEvent.mouseLocation, expanded: !messages.isEmpty) }
        historyPanel.makeKeyAndOrderFront(nil)
        focusToken += 1
    }

    func hidePanel() {
        historyPanel.orderOut(nil)
    }

    func escape() {
        if pendingAction != nil { decide(.stop) }
        else if isBusy || narrator.isActive { cancelWork() }
        else if card.isVisible { card.hide() }
        else { hidePanel() }
    }

    func clear() {
        cancelWork()
        messages = []
        history = []
    }

    func recapture() {
        beginSnapshot()
    }

    private func showNotice(_ text: String) {
        card.show(.notice(text), focus: false, autoHideAfter: 10)
    }

    /// A short status caption on the buddy that clears itself.
    private func flash(_ text: String, for seconds: TimeInterval = 2.5) {
        buddy.setCaption(text, style: .status)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.buddy.model.caption == text { self?.buddy.setCaption(nil) }
        }
    }

    /// Status captions ("▸ Open Spotify") never interrupt a sentence being spoken.
    private func status(_ text: String) {
        guard !narrator.isPlaying else { return }
        buddy.setCaption(text, style: .status)
    }

    // MARK: Screen

    private func beginSnapshot() {
        let focus = ScreenReader.focusInfo()
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main else { return }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        screenSummary = "Reading screen…"
        let wantsScreenshot = usesClaude
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            do {
                let image = try await ScreenReader.capture(displayID: displayID, pixelScale: scale)
                async let jpeg = wantsScreenshot ? Task.detached(priority: .userInitiated) { ScreenReader.jpeg(image) }.value : nil
                let elements = try await ScreenReader.recognizeText(in: image, screenFrame: frame)
                self?.screenSummary = "\(focus.appName ?? "Screen") · \(elements.count) lines"
                let context = ScreenContext(appName: focus.appName, windowTitle: focus.windowTitle, elements: elements, cursor: cursor)
                let snapshot = Snapshot(context: context, image: image, screenFrame: frame, jpeg: await jpeg)
                self?.latestSnapshot = snapshot
                return snapshot
            } catch {
                guard let self else { return nil }
                screenSummary = "Screen unavailable"
                if !warnedAboutScreen {
                    warnedAboutScreen = true
                    note(error.localizedDescription)
                    showNotice(error.localizedDescription)
                }
                return nil
            }
        }
    }

    // MARK: Voice input

    func beginVoice() {
        guard pendingAction == nil else { return } // don't clobber an action waiting for approval
        voiceRequested = true
        cancelWork() // talking interrupts whatever it was saying
        if card.isVisible { card.hide() }
        beginSnapshot()
        buddy.setMode(.listening)
        Task {
            do {
                try await SpeechInput.requestPermissions()
                guard voiceRequested else {
                    buddy.setMode(.idle)
                    return
                }
                try speechIn.start()
            } catch {
                voiceRequested = false
                buddy.setMode(.idle)
                fail(error)
            }
        }
    }

    func endVoice() {
        voiceRequested = false
        guard speechIn.isRunning else {
            if buddy.model.mode == .listening { buddy.setMode(.idle) }
            return
        }
        Task {
            let text = await speechIn.stop()
            guard !text.isEmpty else {
                buddy.setMode(.idle)
                buddy.setCaption(nil)
                return
            }
            submit(text, spoken: true) // resets the buddy, so show the question afterwards
            buddy.setCaption(text, style: .user)
        }
    }

    func cancelVoice() {
        voiceRequested = false
        speechIn.cancel()
        buddy.setMode(.idle)
        buddy.setCaption(nil)
    }

    // MARK: Requests

    func submitInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pendingAction == nil else { return }
        input = ""
        if card.content == .input { card.hide() }
        submit(text, spoken: false)
    }

    private func submit(_ raw: String, spoken: Bool) {
        let text = Prompts.parseMode(raw).text // "agent:" is optional now
        guard !text.isEmpty else { return }
        log.info("request (\(spoken ? "voice" : "typed", privacy: .public)): \(text, privacy: .public)")
        cancelWork()
        if card.isVisible { card.hide() }
        append(DisplayMessage(kind: .user, text: raw))
        let snapshotTask = includeScreen ? self.snapshotTask : nil
        let speak = spoken ? config.speakReplies : config.speakTypedReplies
        let current = generation
        isBusy = true
        buddy.setMode(.thinking)
        workTask = Task { [weak self] in
            let snapshot = await snapshotTask?.value
            guard let self, !Task.isCancelled else { return }
            if usesClaude, let apiKey = APIKeyStore.read() {
                await runClaude(request: text, snapshot: snapshot, speak: speak, apiKey: apiKey)
            } else if let vision = visionModel, let snapshot, VisionRouting.shouldUseVision(
                mode: config.visionMode, hasVisionModel: true, ocrCharacters: snapshot.context.characterCount, question: text
            ) {
                await runVision(question: text, model: vision, snapshot: snapshot, speak: speak)
            } else {
                await runAssistant(request: text, snapshot: snapshot, speak: speak)
            }
            if generation == current { isBusy = false }
        }
    }

    // MARK: Claude

    var usesClaude: Bool { config.brain == "claude" }
    var hasAPIKey: Bool { APIKeyStore.read() != nil }
    private var toldAboutMissingKey = false

    func setAPIKey(_ key: String?) {
        if let key, !key.isEmpty {
            APIKeyStore.save(key)
            update { $0.brain = "claude" }
            flash("Got it — I'm using Claude now.")
        } else {
            APIKeyStore.delete()
            flash("Claude key removed — I'll use the local model.")
        }
    }

    private func runClaude(request: String, snapshot: Snapshot?, speak: Bool, apiKey: String) async {
        let executor = AgentExecutor(workingDirectory: config.agentWorkingDirectory, timeout: config.commandTimeout) { [weak self] action in
            await self?.performUI(action) ?? "Companion is shutting down."
        }
        let loop = ClaudeAgentLoop(
            client: AnthropicClient(apiKey: apiKey), model: config.claudeModel, effort: config.claudeEffort,
            executor: executor, maxSteps: config.agentMaxSteps, policy: config.approvalPolicy,
            captureScreen: { [weak self] in await self?.freshCapture() }
        )
        agentTurnID = nil
        agentStepID = nil
        activeModel = config.claudeModel
        beginNarration(voiced: speak, snapshot: snapshot)
        log.info("brain: \(self.config.claudeModel, privacy: .public), screenshot: \(snapshot?.jpeg != nil, privacy: .public)")
        do {
            let answer = try await loop.run(
                request: request,
                screen: snapshot?.capture,
                history: Array(history.suffix(8)),
                confirm: { [weak self] action in await self?.confirm(action) ?? .stop },
                emit: { [weak self] event in await self?.handle(event) }
            )
            if !answer.isEmpty { remember(question: request, answer: ReplyParsing.extractPoints(from: answer).clean) }
        } catch let error as ClaudeError where error.suggestsLocalFallback && !Task.isCancelled {
            log.error("claude unavailable, falling back to local: \(error.localizedDescription, privacy: .public)")
            stopNarration()
            flash("Claude isn't reachable — using the local model.")
            await runAssistant(request: request, snapshot: snapshot, speak: speak)
            return
        } catch {
            if !Task.isCancelled && !(error is CancellationError) {
                stopNarration()
                fail(error)
            }
        }
        pendingAction = nil
        if case .approval = card.content { card.hide() }
    }

    /// A new screen reading for read_screen, including the screenshot.
    private func freshCapture() async -> ScreenCapture? {
        try? await Task.sleep(for: .milliseconds(300)) // let the UI settle after the last action
        beginSnapshot()
        guard let snapshot = await snapshotTask?.value else { return nil }
        return snapshot.capture
    }

    func cancelWork() {
        decide(.stop)
        workTask?.cancel()
        workTask = nil
        generation += 1
        isBusy = false
        stopNarration()
        if case .approval = card.content { card.hide() }
        buddy.setMode(.idle)
    }

    private func fail(_ error: Error) {
        log.error("failed: \(error.localizedDescription, privacy: .public)")
        append(DisplayMessage(kind: .error, text: error.localizedDescription))
        buddy.setMode(.idle)
        buddy.setCaption(nil)
        showNotice(error.localizedDescription)
    }

    /// Questions about images, diagrams or UI layout go to the local vision model (no tools).
    private func runVision(question: String, model: String, snapshot: Snapshot, speak: Bool) async {
        let image = snapshot.image
        let images = await Task.detached(priority: .userInitiated) { ScreenReader.jpeg(image)?.base64 }.value.map { [$0] }
        let request = [ChatMessage(role: .system, content: Prompts.interactive(hasImage: images != nil))]
            + history.suffix(8)
            + [ChatMessage(role: .user, content: snapshot.context.promptBlock() + "\n\n" + question, images: images)]

        let replyID = append(DisplayMessage(kind: .assistant, text: ""))
        activeModel = model
        beginNarration(voiced: speak, snapshot: snapshot)
        var reply = ""
        do {
            for try await chunk in client.chat(model: model, messages: request, options: options(for: model)) {
                guard let delta = chunk.message?.content, !delta.isEmpty else { continue }
                reply += delta
                updateMessage(replyID) { $0.text = ReplyParsing.extractPoints(from: reply).clean }
                streamTurn(reply)
            }
        } catch {
            if !Task.isCancelled {
                removeIfEmpty(replyID)
                stopNarration()
                fail(error)
            }
            return
        }
        guard !Task.isCancelled else { return }
        let clean = ReplyParsing.extractPoints(from: reply).clean
        updateMessage(replyID) { $0.text = clean.isEmpty ? "_(empty reply)_" : clean }
        remember(question: question, answer: clean)
        finishNarration(finalText: reply)
    }

    // MARK: Assistant (answers and actions)

    private func runAssistant(request: String, snapshot: Snapshot?, speak: Bool) async {
        if usesClaude && !hasAPIKey && !toldAboutMissingKey {
            toldAboutMissingKey = true
            showNotice("Using the local model for now. Add a Claude API key from the menu bar (Claude API Key…) so I can see your screen and act much more reliably.")
        }
        let executor = AgentExecutor(workingDirectory: config.agentWorkingDirectory, timeout: config.commandTimeout) { [weak self] action in
            await self?.performUI(action) ?? "Companion is shutting down."
        }
        let loop = AgentLoop(client: client, model: config.chatModel, options: options(for: config.chatModel),
                             executor: executor, maxSteps: config.agentMaxSteps, policy: config.approvalPolicy)
        agentTurnID = nil
        agentStepID = nil
        activeModel = config.chatModel
        beginNarration(voiced: speak, snapshot: snapshot)
        do {
            let answer = try await loop.run(
                request: request,
                screen: snapshot?.context.promptBlock(),
                history: Array(history.suffix(8)),
                confirm: { [weak self] action in await self?.confirm(action) ?? .stop },
                emit: { [weak self] event in await self?.handle(event) }
            )
            if !answer.isEmpty { remember(question: request, answer: ReplyParsing.extractPoints(from: answer).clean) }
        } catch {
            if !Task.isCancelled && !(error is CancellationError) {
                stopNarration()
                fail(error)
            }
        }
        pendingAction = nil
        if case .approval = card.content { card.hide() }
    }

    private func remember(question: String, answer: String) {
        history.append(ChatMessage(role: .user, content: question))
        history.append(ChatMessage(role: .assistant, content: answer))
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .turnStarted:
            settleTurn()
            turnText = ""
            turnSpoken = 0
            agentTurnID = nil
        case .thinking(let text):
            guard !text.isEmpty else { return }
            if let id = agentTurnID {
                updateMessage(id) { $0.text = ReplyParsing.extractPoints(from: text).clean }
            } else {
                agentTurnID = append(DisplayMessage(kind: .assistant, text: ReplyParsing.extractPoints(from: text).clean))
            }
            streamTurn(text)
        case .proposed(let action):
            log.info("needs approval: \(action.title, privacy: .public) — \(action.detail, privacy: .public)")
            settleTurn()
            agentStepID = append(DisplayMessage(kind: .step, text: "", action: action, stepState: .awaiting))
        case .running(let action):
            log.info("running: \(action.title, privacy: .public) — \(action.detail, privacy: .public)")
            settleTurn()
            agentStepID = append(DisplayMessage(kind: .step, text: "", action: action, stepState: .running))
            buddy.setMode(.thinking)
            status("▸ \(action.title)")
        case .output(let action, let output):
            log.info("result of \(action.title, privacy: .public): \(String(output.prefix(400)), privacy: .public)")
            if output.hasPrefix("Error: macOS blocked") || output.hasPrefix("Error: Accessibility") {
                showNotice(output.replacingOccurrences(of: "Error: ", with: "").replacingOccurrences(of: "Tell the user to allow", with: "Allow"))
            }
            if case .invalid = action {
                append(DisplayMessage(kind: .step, text: "", action: action, stepState: .done(output)))
            } else if let id = agentStepID {
                updateMessage(id) { $0.stepState = .done(output) }
            }
            buddy.setMode(.thinking)
        case .skipped:
            status("Skipped — finding another way…")
        case .finished(let text):
            log.info("answer: \(text, privacy: .public)")
            finishNarration(finalText: text)
        case .stopped:
            note("Stopped.")
            finishNarration(finalText: "")
            flash("Stopped.")
        }
    }

    private func confirm(_ action: AgentAction) async -> AgentDecision {
        guard !Task.isCancelled else { return .stop }
        pendingAction = action
        buddy.setMode(.idle)
        status("Okay to \(action.title.lowercased())?")
        card.show(.approval(action), focus: true)
        let decision = await withCheckedContinuation { confirmation = $0 }
        pendingAction = nil
        if case .approval = card.content { card.hide() }
        if let id = agentStepID {
            updateMessage(id) {
                switch decision {
                case .run: $0.stepState = .running
                case .skip: $0.stepState = .skipped
                case .stop: $0.stepState = .stopped
                }
            }
        }
        if decision == .run {
            buddy.setMode(.thinking)
            status("▸ \(action.title)")
        }
        return decision
    }

    func decide(_ decision: AgentDecision) {
        let continuation = confirmation
        confirmation = nil
        continuation?.resume(returning: decision)
    }

    /// Screen, mouse, keyboard and media actions — the parts of the toolset that need AppKit.
    private func performUI(_ action: AgentAction) async -> String {
        switch action {
        case .media, .typeText, .pressKeys, .click:
            // Without Accessibility, macOS silently drops synthetic input — say so instead.
            guard AXIsProcessTrusted() else {
                checkSetup(reportIfFine: false)
                return "Error: Accessibility permission is off for Companion, so macOS ignores its clicks and key presses. Tell the user to enable Companion in System Settings > Privacy & Security > Accessibility."
            }
            return await performInput(action)
        case .readScreen:
            try? await Task.sleep(for: .milliseconds(300)) // let the UI settle after the last action
            beginSnapshot()
            guard let snapshot = await snapshotTask?.value else { return "Couldn't read the screen — Screen Recording permission may be off." }
            return snapshot.context.promptBlock(budget: 3000)
        default:
            return "Unsupported action."
        }
    }

    private func performInput(_ action: AgentAction) async -> String {
        switch action {
        case .media(let command):
            return MacControl.media(command)
        case .typeText(let text):
            return MacControl.typeText(text)
        case .pressKeys(let keys):
            return MacControl.pressKeys(keys)
        case .click(let target):
            if let (x, y) = ReplyParsing.coordinatePair(target) {
                guard let point = latestSnapshot?.screenPoint(fromImage: CGPoint(x: x, y: y)) else {
                    return "Coordinates need a screenshot. Call read_screen first."
                }
                buddy.point(to: point)
                highlights.show([CGRect(x: point.x - 18, y: point.y - 14, width: 36, height: 28)])
                try? await Task.sleep(for: .milliseconds(450))
                MacControl.click(at: point)
                try? await Task.sleep(for: .milliseconds(250))
                highlights.clear()
                buddy.release()
                return "Clicked at \(Int(x)),\(Int(y))."
            }
            guard let element = latestSnapshot.flatMap({ Self.element(matching: target, in: $0.context) }) else {
                return "Couldn't find \"\(target)\" on screen. Call read_screen for fresh element ids."
            }
            // Show where it's clicking, like a person would, then click.
            buddy.point(at: element.frame)
            highlights.show([element.frame])
            try? await Task.sleep(for: .milliseconds(450))
            MacControl.click(at: CGPoint(x: element.frame.midX, y: element.frame.midY))
            try? await Task.sleep(for: .milliseconds(250))
            highlights.clear()
            buddy.release()
            return "Clicked \"\(element.text)\"."
        default:
            return "Unsupported action."
        }
    }

    /// An element by `[id]`, else by visible text (exact match first, then the tightest containing match).
    static func element(matching target: String, in context: ScreenContext) -> TextElement? {
        let trimmed = target.trimmingCharacters(in: CharacterSet(charactersIn: "[] \""))
        if let id = Int(trimmed) { return context.element(id: id) }
        if let exact = context.elements.first(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) { return exact }
        return context.elements
            .filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
            .min { $0.text.count < $1.text.count }
    }

    // MARK: Narration

    private var narrationEngine: Narrator.Engine {
        if config.voice.hasPrefix("system:") { return .system(name: String(config.voice.dropFirst("system:".count))) }
        return voiceServer.isReady ? .neural(voice: config.voice) : .system(name: "Moira")
    }

    private func beginNarration(voiced: Bool, snapshot: Snapshot?) {
        stopNarration()
        if let snapshot { latestSnapshot = snapshot }
        turnText = ""
        turnSpoken = 0
        narrator.begin(engine: voiced ? narrationEngine : .silent, speed: config.speechSpeed)
    }

    /// Queues the settled sentences of the current turn as they stream in.
    private func streamTurn(_ text: String) {
        turnText = text
        let steps = ReplyParsing.narration(from: text, final: false).steps
        while turnSpoken < steps.count {
            narrator.enqueue(steps[turnSpoken])
            turnSpoken += 1
        }
    }

    /// The turn is over (a tool call follows, or a new turn starts): queue its remaining sentences.
    private func settleTurn() {
        let steps = ReplyParsing.narration(from: turnText, final: true).steps
        while turnSpoken < steps.count {
            narrator.enqueue(steps[turnSpoken])
            turnSpoken += 1
        }
    }

    private func finishNarration(finalText: String) {
        turnText = finalText
        settleTurn()
        let narration = ReplyParsing.narration(from: finalText, final: true)
        if !narration.code.isEmpty { card.show(.code(narration.code), focus: false) }
        if !narrator.isPlaying { buddy.setMode(.idle) }
        narrator.finishInput()
    }

    private func stopNarration() {
        narrator.stop()
        narrationToken += 1
        highlights.clear()
        buddy.release()
        buddy.setCaption(nil)
    }

    /// A sentence starts playing: caption it, and point at / highlight what it refers to.
    private func present(_ step: NarrationStep) {
        buddy.setMode(.speaking)
        buddy.setCaption(step.text, style: .spoken)
        let rects = step.points.compactMap { point in latestSnapshot.flatMap { rect(for: point, in: $0) } }
        guard let first = rects.first else { return }
        if let coordinates = step.points.first?.coordinates, let tip = latestSnapshot?.screenPoint(fromImage: coordinates) {
            buddy.point(to: tip)
        } else {
            buddy.point(at: first)
        }
        highlights.show(rects)
    }

    /// The on-screen rectangle a point tag refers to: an OCR line, or a small box around a pixel coordinate.
    private func rect(for point: PointTag, in snapshot: Snapshot) -> CGRect? {
        if let id = point.elementID { return snapshot.context.element(id: id)?.frame }
        guard let coordinates = point.coordinates, let center = snapshot.screenPoint(fromImage: coordinates) else { return nil }
        return CGRect(x: center.x - 18, y: center.y - 14, width: 36, height: 28)
    }

    private func narrationFinished() {
        if !isBusy { buddy.setMode(.idle) }
        let token = narrationToken
        // Linger briefly on the last caption and highlight, then glide back to the cursor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, token == narrationToken, !narrator.isActive else { return }
            buddy.setCaption(nil)
            buddy.release()
            highlights.clear()
        }
    }

    // MARK: Messages (history panel)

    @discardableResult
    private func append(_ message: DisplayMessage) -> UUID {
        messages.append(message)
        return message.id
    }

    private func updateMessage(_ id: UUID, _ change: (inout DisplayMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func removeIfEmpty(_ id: UUID) {
        messages.removeAll { $0.id == id && $0.text.isEmpty }
    }

    func note(_ text: String) {
        append(DisplayMessage(kind: .note, text: text))
    }
}
