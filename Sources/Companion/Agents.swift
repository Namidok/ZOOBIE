import AppKit
import CompanionCore
import os

private let log = Logger(subsystem: "local.companion.agent", category: "agents")

/// ZOOBIE's four persistent specialists. Each works through its own queue of delegated tasks (one at a
/// time; the four run in parallel), keeps a notebook and a conversation thread, and never touches the
/// screen, mouse or keyboard while working in the background. Risky steps queue up for approval.
@MainActor
final class AgentManager: ObservableObject {
    struct Approval: Identifiable {
        let id = UUID()
        let runID: UUID
        let agent: Specialist.ID?
        let title: String
        let action: AgentAction
    }

    static let avatarsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Companion/avatars")

    @Published private(set) var runs: [AgentRun]
    @Published private(set) var approvals: [Approval] = []
    /// Bumped when a notebook or thread changes, so views showing them refresh.
    @Published private(set) var memoryVersion = 0
    /// German practice: transcribe the user in German instead of English.
    @Published var germanSpeechInput = UserDefaults.standard.bool(forKey: "germanSpeechInput") {
        didSet { UserDefaults.standard.set(germanSpeechInput, forKey: "germanSpeechInput") }
    }

    var onFinished: (AgentRun) -> Void = { _ in }
    var onNeedsApproval: () -> Void = {}
    /// Supplies the current settings (names, model, policy) when a task starts.
    var config: () -> CompanionConfig = { CompanionConfig() }

    let memory = SpecialistStore()
    private let store = AgentRunStore()
    private var workers: [Specialist.ID: Task<Void, Never>] = [:]
    private var waiting: [UUID: CheckedContinuation<AgentDecision, Never>] = [:]

    init() {
        runs = store.load()
    }

    // MARK: Identity

    func name(_ id: Specialist.ID) -> String {
        let custom = config().agentNames[id.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? Specialist.get(id).defaultName : custom
    }

    /// This specialist's avatar: the user's own from Application Support if they've added one, else the
    /// one bundled with the app (Resources/avatars). Cached, since views ask on every redraw.
    func avatar(_ id: Specialist.ID) -> NSImage? {
        if let cached = avatarCache[id] { return cached }
        var found: NSImage?
        for ext in ["png", "jpg", "jpeg", "heic", "webp"] where found == nil {
            found = NSImage(contentsOf: Self.avatarsDirectory.appendingPathComponent("\(id.rawValue).\(ext)"))
        }
        if found == nil, let url = Bundle.main.url(forResource: id.rawValue, withExtension: "png", subdirectory: "avatars") {
            found = NSImage(contentsOf: url)
        }
        #if DEBUG
        // `swift run` has no app bundle: use the repo's copy.
        if found == nil { found = NSImage(contentsOfFile: "Resources/avatars/\(id.rawValue).png") }
        #endif
        if let found { avatarCache[id] = found }
        return found
    }

    private var avatarCache: [Specialist.ID: NSImage] = [:]

    // MARK: Status

    var activeCount: Int { runs.filter(\.status.isActive).count }

    func runs(for id: Specialist.ID) -> [AgentRun] { runs.filter { $0.agent == id } }

    func current(_ id: Specialist.ID) -> AgentRun? {
        runs.first { $0.agent == id && ($0.status == .running || $0.status == .waiting) }
    }

    func queued(_ id: Specialist.ID) -> Int { runs.filter { $0.agent == id && $0.status == .queued }.count }

    func statusLine(_ id: Specialist.ID) -> String {
        if let run = current(id) {
            if run.status == .waiting { return "Waiting for your OK" }
            return run.steps.last.map { "\(run.title): \($0)" } ?? "Working on \(run.title)"
        }
        let waitingCount = queued(id)
        if waitingCount > 0 { return "\(waitingCount) task\(waitingCount == 1 ? "" : "s") queued" }
        if let last = runs(for: id).first(where: { $0.status == .done }) { return "Last: \(last.summary ?? last.title)" }
        return "Idle — ready for a task"
    }

    // MARK: Tasks

    /// Queues a task for a specialist. Returns an error message instead when it can't run.
    @discardableResult
    func delegate(to id: Specialist.ID, title: String, task: String) -> String? {
        guard APIKeyStore.read() != nil else {
            return "The specialists need the Claude brain. Add a Claude API key in Settings first."
        }
        let run = AgentRun(title: title, task: task, agent: id)
        runs.insert(run, at: 0)
        store.save(run)
        log.notice("delegated to \(id.rawValue, privacy: .public): \(title, privacy: .public)")
        pump(id)
        return nil
    }

    func cancel(_ runID: UUID) {
        guard let run = runs.first(where: { $0.id == runID }) else { return }
        if let agent = run.agent, current(agent)?.id == runID {
            workers[agent]?.cancel()
            workers[agent] = nil
        }
        for approval in approvals where approval.runID == runID { decide(approval.id, .stop) }
        update(runID) {
            $0.status = .cancelled
            $0.finishedAt = Date()
        }
        if let agent = run.agent { pump(agent) }
    }

    func remove(_ runID: UUID) {
        cancel(runID)
        if let run = runs.first(where: { $0.id == runID }) { store.delete(run) }
        runs.removeAll { $0.id == runID }
    }

    func clearFinished(_ id: Specialist.ID? = nil) {
        for run in runs where !run.status.isActive && (id == nil || run.agent == id) { store.delete(run) }
        runs.removeAll { !$0.status.isActive && (id == nil || $0.agent == id) }
    }

    /// Forgets a specialist's notebook and conversation.
    func clearMemory(_ id: Specialist.ID) {
        memory.clear(id)
        memoryVersion += 1
    }

    func decide(_ approvalID: UUID, _ decision: AgentDecision) {
        guard let index = approvals.firstIndex(where: { $0.id == approvalID }) else { return }
        let approval = approvals.remove(at: index)
        waiting.removeValue(forKey: approval.id)?.resume(returning: decision)
    }

    /// Starts the oldest queued task for this specialist if it's free.
    private func pump(_ id: Specialist.ID) {
        guard workers[id] == nil, let next = runs.last(where: { $0.agent == id && $0.status == .queued }) else { return }
        guard let apiKey = APIKeyStore.read() else { return }
        update(next.id) { $0.status = .running }
        let config = config()
        workers[id] = Task { [weak self] in
            await self?.execute(next, agent: id, apiKey: apiKey, config: config)
            guard let self else { return }
            self.workers[id] = nil
            self.pump(id)
        }
    }

    private func execute(_ run: AgentRun, agent id: Specialist.ID, apiKey: String, config: CompanionConfig) async {
        let specialist = Specialist.get(id)
        let executor = AgentExecutor(workingDirectory: config.agentWorkingDirectory, timeout: config.commandTimeout,
                                     ui: { [weak self] action in await self?.backgroundUI(action) ?? "Unavailable." },
                                     notebookURL: memory.notebookURL(id))
        let loop = ClaudeAgentLoop(
            client: AnthropicClient(apiKey: apiKey), model: config.claudeModel, effort: specialist.effort,
            executor: executor, maxSteps: 30, policy: config.approvalPolicy,
            role: .specialist(specialist, name: name(id), notebook: memory.notebook(id), conversation: false),
            captureScreen: { nil }
        )
        do {
            let report = try await loop.run(
                request: run.task, screen: nil, history: Array(memory.thread(id).suffix(6)),
                confirm: { [weak self] action in await self?.requestApproval(run.id, agent: id, action) ?? .stop },
                emit: { [weak self] event in await self?.handle(run.id, event) }
            )
            guard !Task.isCancelled else { return }
            finish(run.id, agent: id, report: report)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            log.error("\(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            update(run.id) {
                $0.status = .failed
                $0.error = error.localizedDescription
                $0.finishedAt = Date()
            }
        }
    }

    /// Timers are the only app-level action a background specialist (the Scheduler) may use.
    var timerHandler: (AgentAction) -> String = { _ in "Timers are unavailable." }

    private func backgroundUI(_ action: AgentAction) -> String {
        switch action {
        case .setTimer, .listTimers, .cancelTimer: return timerHandler(action)
        default: return "Error: background specialists can't use \(action.title)."
        }
    }

    private func handle(_ runID: UUID, _ event: AgentEvent) {
        switch event {
        case .running(let action), .proposed(let action):
            update(runID) { $0.log(Self.describe(action)) }
            if case .updateNotebook = action { memoryVersion += 1 }
        case .research(let line):
            update(runID) { $0.log(line) }
        case .skipped(let action):
            update(runID) { $0.log("Skipped: \(action.title)") }
        default:
            break
        }
    }

    private func requestApproval(_ runID: UUID, agent: Specialist.ID, _ action: AgentAction) async -> AgentDecision {
        guard let run = runs.first(where: { $0.id == runID }), !Task.isCancelled else { return .stop }
        update(runID) { $0.status = .waiting }
        let approval = Approval(runID: runID, agent: agent, title: "\(name(agent)) · \(run.title)", action: action)
        let decision = await withCheckedContinuation { continuation in
            waiting[approval.id] = continuation
            approvals.append(approval)
            onNeedsApproval()
        }
        if decision != .stop { update(runID) { $0.status = .running } }
        return decision
    }

    private func finish(_ runID: UUID, agent: Specialist.ID, report: String) {
        var finished: AgentRun?
        update(runID) { run in
            run.report = report
            run.reportPath = report.isEmpty ? nil : store.writeReport(report, for: run)
            run.status = report.isEmpty ? .cancelled : .done
            run.finishedAt = Date()
            finished = run
        }
        guard let finished, finished.status == .done else { return }
        // The specialist remembers what it did, so later conversations and tasks can build on it.
        memory.append([
            ChatMessage(role: .user, content: "Task: \(finished.title)\n\(finished.task)"),
            ChatMessage(role: .assistant, content: String(report.prefix(1500)) + (finished.reportPath.map { "\n\n(Full report: \($0))" } ?? "")),
        ], to: agent)
        memoryVersion += 1
        log.notice("\(agent.rawValue, privacy: .public) done: \(finished.title, privacy: .public)")
        onFinished(finished)
    }

    // MARK: Conversation (talking to a specialist directly)

    func conversationHistory(_ id: Specialist.ID) -> [ChatMessage] { Array(memory.thread(id).suffix(12)) }

    func recordConversation(_ id: Specialist.ID, question: String, answer: String) {
        memory.append([ChatMessage(role: .user, content: question), ChatMessage(role: .assistant, content: answer)], to: id)
        memoryVersion += 1
    }

    private func update(_ runID: UUID, _ change: (inout AgentRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        change(&runs[index])
        store.save(runs[index])
    }

    private static func describe(_ action: AgentAction) -> String {
        let detail = action.detail.split(separator: "\n").first.map { String($0.prefix(80)) } ?? ""
        return detail.isEmpty ? action.title : "\(action.title): \(detail)"
    }
}

// MARK: - Timers

/// Countdown timers that survive restarts and announce themselves when they end.
@MainActor
final class TimerManager: ObservableObject {
    struct Item: Identifiable, Codable, Equatable {
        var id = UUID()
        var label: String
        var ends: Date
        var seconds: Int

        var remaining: TimeInterval { max(0, ends.timeIntervalSinceNow) }
    }

    @Published private(set) var timers: [Item] = []
    var onFire: (Item) -> Void = { _ in }
    private var ticker: Timer?
    private static let key = "timers"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            timers = saved
        }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    var next: Item? { timers.min { $0.ends < $1.ends } }

    func start(seconds: Int, label: String) -> String {
        timers.append(Item(label: label, ends: Date().addingTimeInterval(TimeInterval(seconds)), seconds: seconds))
        save()
        return "Started a \(Self.format(TimeInterval(seconds))) timer for \(label)."
    }

    func list() -> String {
        guard !timers.isEmpty else { return "No timers running." }
        return timers.sorted { $0.ends < $1.ends }.map { "\($0.label): \(Self.format($0.remaining)) left" }.joined(separator: "\n")
    }

    func cancel(_ label: String) -> String {
        let before = timers.count
        if label.lowercased() == "all" { timers.removeAll() } else { timers.removeAll { $0.label.localizedCaseInsensitiveContains(label) } }
        save()
        let removed = before - timers.count
        return removed == 0 ? "No timer matched \(label)." : "Cancelled \(removed) timer\(removed == 1 ? "" : "s")."
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    private func tick() {
        guard !timers.isEmpty else { return }
        let fired = timers.filter { $0.remaining <= 0 }
        if !fired.isEmpty {
            timers.removeAll { $0.remaining <= 0 }
            save()
            fired.forEach(onFire)
        } else {
            objectWillChange.send() // refresh countdowns
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(timers), forKey: Self.key)
    }
}
