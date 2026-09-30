import Foundation

/// Arbitrary JSON, used for tool schemas and tool-call arguments.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// Lenient scalar view: small models sometimes send numbers or bools where strings are expected.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public enum VisionMode: String, Codable, Sendable {
    /// Use the vision model only when OCR finds little text or the question is visual.
    case auto
    case always
    case never
}

/// User-editable settings, stored at ~/Library/Application Support/Companion/config.json.
/// Missing keys fall back to defaults so the file can stay minimal.
public struct CompanionConfig: Codable, Sendable, Equatable {
    public var ollamaURL = URL(string: "http://127.0.0.1:11434")!
    /// "claude" (sees the screen, best results; needs an API key) or "local" (Ollama only, fully private).
    public var brain = "claude"
    public var claudeModel = "claude-opus-5-5"
    /// Claude effort: low keeps voice replies quick; raise it for harder tasks.
    public var claudeEffort = "low"
    /// The local model that answers and acts (needs tool-calling ability); also the offline fallback.
    public var chatModel = "qwen2.5-coder:7b"
    /// nil = auto-detect the first installed model with the "vision" capability.
    public var visionModel: String? = nil
    public var visionMode = VisionMode.auto
    /// Speak the one-line summary of answers to voice questions.
    public var speakReplies = true
    /// Also speak answers to typed questions.
    public var speakTypedReplies = false
    public var showBuddy = true
    /// A Kokoro voice id (e.g. "bf_emma") for the neural voice, or "system:<Name>" for an Apple voice.
    public var voice = "bf_emma"
    public var speechSpeed = 1.05
    public var approvalPolicy = ApprovalPolicy.risky
    public var agentWorkingDirectory = "~"
    public var agentMaxSteps = 12
    public var commandTimeout: Double = 60
    public var numCtx = 8192
    public var keepAlive = "30m"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case ollamaURL, brain, claudeModel, claudeEffort, chatModel, visionModel, visionMode, speakReplies, speakTypedReplies, showBuddy, voice, speechSpeed, approvalPolicy
        case agentWorkingDirectory, agentMaxSteps, commandTimeout, numCtx, keepAlive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompanionConfig()
        ollamaURL = try c.decodeIfPresent(URL.self, forKey: .ollamaURL) ?? d.ollamaURL
        brain = try c.decodeIfPresent(String.self, forKey: .brain) ?? d.brain
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        claudeEffort = try c.decodeIfPresent(String.self, forKey: .claudeEffort) ?? d.claudeEffort
        chatModel = try c.decodeIfPresent(String.self, forKey: .chatModel) ?? d.chatModel
        visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel)
        visionMode = try c.decodeIfPresent(VisionMode.self, forKey: .visionMode) ?? d.visionMode
        speakReplies = try c.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? d.speakReplies
        speakTypedReplies = try c.decodeIfPresent(Bool.self, forKey: .speakTypedReplies) ?? d.speakTypedReplies
        showBuddy = try c.decodeIfPresent(Bool.self, forKey: .showBuddy) ?? d.showBuddy
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? d.voice
        speechSpeed = try c.decodeIfPresent(Double.self, forKey: .speechSpeed) ?? d.speechSpeed
        approvalPolicy = try c.decodeIfPresent(ApprovalPolicy.self, forKey: .approvalPolicy) ?? d.approvalPolicy
        agentWorkingDirectory = try c.decodeIfPresent(String.self, forKey: .agentWorkingDirectory) ?? d.agentWorkingDirectory
        agentMaxSteps = try c.decodeIfPresent(Int.self, forKey: .agentMaxSteps) ?? d.agentMaxSteps
        commandTimeout = try c.decodeIfPresent(Double.self, forKey: .commandTimeout) ?? d.commandTimeout
        numCtx = try c.decodeIfPresent(Int.self, forKey: .numCtx) ?? d.numCtx
        keepAlive = try c.decodeIfPresent(String.self, forKey: .keepAlive) ?? d.keepAlive
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Companion/config.json")
    }

    /// Loads the config, writing defaults on first run. A malformed file is left untouched and defaults are used.
    public static func load(from url: URL = fileURL) -> CompanionConfig {
        if let data = try? Data(contentsOf: url) {
            return (try? JSONDecoder().decode(CompanionConfig.self, from: data)) ?? CompanionConfig()
        }
        let config = CompanionConfig()
        try? config.save(to: url)
        return config
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
