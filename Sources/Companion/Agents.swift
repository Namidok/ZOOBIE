import AppKit
import CompanionCore
import os

private let log = Logger(subsystem: "local.companion.agent", category: "agents")

/// Runs background agents: each is a Claude worker loop with web research, files, shell and AppleScript —
/// never the screen, mouse or keyboard. Several can run at once; risky steps queue up for approval.
@MainActor
final class AgentManager: ObservableObject {
    struct Approval: Identifiable {
        let id = UUID()
        let runID: UUID
        let title: String
        let action: AgentAction
    }

    @Published private(set) var runs: [AgentRun]
    @Published private(set) var approvals: [Approval] = []

    /// Called when a run finishes successfully (to announce it).
    var onFinished: (AgentRun) -> Void = { _ in }
    /// Called when a run needs the user's OK.
    var onNeedsApproval: () -> Void = {}

    private let store = AgentRunStore()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var waiting: [UUID: CheckedContinuation<AgentDecision, Never>] = [:]

    init() {
        runs = store.load()
    }

    var activeCount: Int { runs.filter(\.status.isActive).count }

    /// Starts a job. Returns an error message instead when it can't run.
    @discardableResult
    func start(title: String, task: String, config: CompanionConfig) -> String? {
        guard let apiKey = APIKeyStore.read() else {
            return "Agents need the Claude brain. Add a Claude API key in Settings first."
        }
        guard activeCount < 4 else { return "Four agents are already working. Wait for one to finish or stop one." }
        let run = AgentRun(title: title, task: task)
        runs.insert(run, at: 0)
        store.save(run)
        log.notice("agent started: \(title, privacy: .public)")
        tasks[run.id] = Task { [weak self] in
            await self?.execute(run.id, task: task, apiKey: apiKey, config: config)
        }
        return nil
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        for approval in approvals where approval.runID == id { decide(approval.id, .stop) }
        update(id) {
            $0.status = .cancelled
            $0.finishedAt = Date()
        }
    }

    func remove(_ id: UUID) {
        cancel(id)
        if let run = runs.first(where: { $0.id == id }) { store.delete(run) }
        runs.removeAll { $0.id == id }
    }

    func clearFinished() {
        for run in runs where !run.status.isActive { store.delete(run) }
        runs.removeAll { !$0.status.isActive }
    }

    func decide(_ approvalID: UUID, _ decision: AgentDecision) {
        guard let index = approvals.firstIndex(where: { $0.id == approvalID }) else { return }
        let approval = approvals.remove(at: index)
        waiting.removeValue(forKey: approval.id)?.resume(returning: decision)
    }

    // MARK: Running

    private func execute(_ id: UUID, task: String, apiKey: String, config: CompanionConfig) async {
        let executor = AgentExecutor(workingDirectory: config.agentWorkingDirectory, timeout: config.commandTimeout)
        let loop = ClaudeAgentLoop(
            client: AnthropicClient(apiKey: apiKey), model: config.claudeModel, effort: "medium",
            executor: executor, maxSteps: 30, policy: config.approvalPolicy, role: .worker,
            captureScreen: { nil }
        )
        do {
            let report = try await loop.run(
                request: task, screen: nil,
                confirm: { [weak self] action in await self?.requestApproval(id, action) ?? .stop },
                emit: { [weak self] event in await self?.handle(id, event) }
            )
            guard !Task.isCancelled else { return }
            finish(id, report: report)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            log.error("agent failed: \(error.localizedDescription, privacy: .public)")
            update(id) {
                $0.status = .failed
                $0.error = error.localizedDescription
                $0.finishedAt = Date()
            }
        }
        tasks[id] = nil
    }

    private func handle(_ id: UUID, _ event: AgentEvent) {
        switch event {
        case .running(let action), .proposed(let action):
            update(id) { $0.log(Self.describe(action)) }
        case .research(let line):
            update(id) { $0.log(line) }
        case .skipped(let action):
            update(id) { $0.log("Skipped: \(action.title)") }
        default:
            break
        }
    }

    private func requestApproval(_ id: UUID, _ action: AgentAction) async -> AgentDecision {
        guard let run = runs.first(where: { $0.id == id }), !Task.isCancelled else { return .stop }
        update(id) { $0.status = .waiting }
        let approval = Approval(runID: id, title: run.title, action: action)
        let decision = await withCheckedContinuation { continuation in
            waiting[approval.id] = continuation
            approvals.append(approval)
            onNeedsApproval()
        }
        if decision != .stop { update(id) { $0.status = .running } }
        return decision
    }

    private func finish(_ id: UUID, report: String) {
        var finished: AgentRun?
        update(id) { run in
            run.report = report
            run.reportPath = store.writeReport(report, for: run)
            run.status = report.isEmpty ? .cancelled : .done
            run.finishedAt = Date()
            finished = run
        }
        if let finished, finished.status == .done {
            log.notice("agent done: \(finished.title, privacy: .public)")
            onFinished(finished)
        }
    }

    private func update(_ id: UUID, _ change: (inout AgentRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[index])
        store.save(runs[index])
    }

    private static func describe(_ action: AgentAction) -> String {
        let detail = action.detail.split(separator: "\n").first.map { String($0.prefix(80)) } ?? ""
        return detail.isEmpty ? action.title : "\(action.title): \(detail)"
    }
}
