import Foundation

/// One background agent job, persisted so the list survives restarts.
public struct AgentRun: Codable, Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case queued, running, waiting, done, failed, cancelled

        public var isActive: Bool { self == .queued || self == .running || self == .waiting }
    }

    public var id: UUID
    /// Which specialist owns it (nil for runs from before specialists existed).
    public var agent: Specialist.ID?
    public var title: String
    public var task: String
    public var status: Status
    public var createdAt: Date
    public var finishedAt: Date?
    /// Short progress lines ("Searching the web: …"), newest last.
    public var steps: [String]
    public var report: String?
    public var reportPath: String?
    public var error: String?

    public init(title: String, task: String, agent: Specialist.ID? = nil) {
        id = UUID()
        self.agent = agent
        self.title = title
        self.task = task
        status = agent == nil ? .running : .queued
        createdAt = Date()
        steps = []
    }

    public mutating func log(_ step: String) {
        steps.append(step)
        if steps.count > 40 { steps.removeFirst(steps.count - 40) }
    }

    /// The report's first line, for speaking and the list view.
    public var summary: String? {
        report?.split(separator: "\n").lazy
            .map { ReplyParsing.stripMarkdown(String($0)) }
            .first { !$0.isEmpty }
    }
}

/// Saves agent runs as JSON in Application Support and reports as Markdown in ~/Documents/ZOOBIE.
public struct AgentRunStore: Sendable {
    public var directory: URL
    public var reportsDirectory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Companion/agents"),
                reportsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ZOOBIE")) {
        self.directory = directory
        self.reportsDirectory = reportsDirectory
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Newest first. Runs that were active when the app quit come back as cancelled.
    public func load() -> [AgentRun] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(AgentRun.self, from: Data(contentsOf: $0)) }
            .map { run in
                var run = run
                if run.status.isActive {
                    run.status = .cancelled
                    run.error = "Stopped when ZOOBIE quit."
                }
                return run
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ run: AgentRun) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Self.encoder.encode(run).write(to: directory.appendingPathComponent("\(run.id.uuidString).json"), options: .atomic)
    }

    public func delete(_ run: AgentRun) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(run.id.uuidString).json"))
    }

    /// Writes the report to ~/Documents/ZOOBIE/<date> <title>.md and returns its path.
    public func writeReport(_ report: String, for run: AgentRun) -> String? {
        try? FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let safeTitle = run.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let url = reportsDirectory.appendingPathComponent("\(formatter.string(from: run.createdAt)) \(safeTitle).md")
        let body = "# \(run.title)\n\n> \(run.task)\n\n\(report)\n"
        return (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil ? url.path : nil
    }
}
