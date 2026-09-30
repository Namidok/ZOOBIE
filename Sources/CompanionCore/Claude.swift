import CoreGraphics
import Foundation

// MARK: - Errors

public enum ClaudeError: LocalizedError {
    case missingKey
    case unauthorized
    case http(Int, String)
    case network(Error)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "No Claude API key yet. Add one from the menu bar: Claude API Key…"
        case .unauthorized: return "Claude rejected the API key. Update it from the menu bar: Claude API Key…"
        case .http(let code, let message): return "Claude returned HTTP \(code): \(message)"
        case .network(let error): return "Couldn't reach Claude: \(error.localizedDescription)"
        }
    }

    /// Worth retrying on the local model instead (offline, overloaded, server trouble).
    public var suggestsLocalFallback: Bool {
        switch self {
        case .network: return true
        case .http(let code, _): return code == 429 || code >= 500
        case .missingKey, .unauthorized: return false
        }
    }
}

// MARK: - Streaming client

/// One streamed assistant turn from the Messages API.
public struct ClaudeTurn: Sendable {
    /// The assistant content blocks, to append unchanged to the conversation (thinking blocks included).
    public var content: [JSONValue]
    /// Visible text across the text blocks.
    public var text: String
    /// Tool calls; `input` is nil when the streamed JSON didn't parse.
    public var toolUses: [(id: String, name: String, input: [String: JSONValue]?)]
    public var stopReason: String?
}

/// Minimal raw-HTTP client for the Claude Messages API (there is no official Swift SDK).
public final class AnthropicClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiKey: String
    private let session: URLSession

    public convenience init(apiKey: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.urlCache = nil
        self.init(apiKey: apiKey, session: URLSession(configuration: config))
    }

    init(apiKey: String, session: URLSession) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Streams one turn. `onText` receives the visible text so far as it grows.
    public func streamTurn(
        model: String,
        effort: String,
        system: String,
        tools: [JSONValue],
        messages: [JSONValue],
        onText: @Sendable (String) async -> Void
    ) async throws -> ClaudeTurn {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(16000),
            "stream": .bool(true),
            // Tools + system are identical on every request, so cache them.
            "system": .array([.object(["type": .string("text"), "text": .string(system), "cache_control": .object(["type": .string("ephemeral")])])]),
            "tools": .array(tools),
            "messages": .array(messages),
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if Self.supportsEffort(model) {
            body["output_config"] = .object(["effort": .string(effort)])
        }
        if Self.supportsServerFallback(model) {
            // On a safety-classifier decline, the API retries on Anthropic's recommended model.
            body["fallbacks"] = .string("default")
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ClaudeError.network(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            if http.statusCode == 401 { throw ClaudeError.unauthorized }
            throw ClaudeError.http(http.statusCode, Self.errorMessage(text) ?? text)
        }

        var accumulator = TurnAccumulator()
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                guard case .object(let event)? = JSONValue.parse(String(line.dropFirst(5))) else { continue }
                if case .string("error")? = event["type"] {
                    let message = Self.errorMessage(String(line.dropFirst(5))) ?? "stream error"
                    throw ClaudeError.http(529, message)
                }
                if accumulator.apply(event) { await onText(accumulator.visibleText) }
                if case .string("message_stop")? = event["type"] { break }
            }
        } catch let error as ClaudeError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ClaudeError.network(error)
        }
        return accumulator.turn()
    }

    static func supportsEffort(_ model: String) -> Bool { !model.contains("haiku") }

    static func supportsServerFallback(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1"].contains(model)
    }

    static func errorMessage(_ body: String) -> String? {
        guard case .object(let object)? = JSONValue.parse(body), case .object(let error)? = object["error"] else { return nil }
        return error["message"]?.stringValue
    }
}

/// Rebuilds content blocks from SSE events.
struct TurnAccumulator {
    private struct Block {
        var start: [String: JSONValue]
        var text = ""
        var partialJSON = ""
        var thinking = ""
        var signature: String?
        var type: String { start["type"]?.stringValue ?? "" }
    }

    private var blocks: [Block] = []
    private var stopReason: String?

    var visibleText: String { blocks.filter { $0.type == "text" }.map(\.text).joined() }

    /// Applies one event; returns true when the visible text changed.
    mutating func apply(_ event: [String: JSONValue]) -> Bool {
        switch event["type"]?.stringValue {
        case "content_block_start":
            guard case .object(let start)? = event["content_block"] else { return false }
            var block = Block(start: start)
            block.text = start["text"]?.stringValue ?? ""
            blocks.append(block)
            return !block.text.isEmpty
        case "content_block_delta":
            guard !blocks.isEmpty, case .object(let delta)? = event["delta"] else { return false }
            let index = blocks.count - 1
            switch delta["type"]?.stringValue {
            case "text_delta":
                blocks[index].text += delta["text"]?.stringValue ?? ""
                return true
            case "input_json_delta":
                blocks[index].partialJSON += delta["partial_json"]?.stringValue ?? ""
            case "thinking_delta":
                blocks[index].thinking += delta["thinking"]?.stringValue ?? ""
            case "signature_delta":
                blocks[index].signature = delta["signature"]?.stringValue
            default:
                break
            }
            return false
        case "message_delta":
            if case .object(let delta)? = event["delta"], let reason = delta["stop_reason"]?.stringValue { stopReason = reason }
            return false
        default:
            return false
        }
    }

    func turn() -> ClaudeTurn {
        // After a mid-output fallback, blocks before the boundary other than text must not be echoed back.
        var kept = blocks
        if let boundary = kept.lastIndex(where: { $0.type == "fallback" }) {
            kept = kept.enumerated().compactMap { index, block in
                if index == boundary { return nil }
                if index < boundary, ["thinking", "redacted_thinking", "tool_use"].contains(block.type) { return nil }
                return block
            }
        }
        var content: [JSONValue] = []
        var toolUses: [(id: String, name: String, input: [String: JSONValue]?)] = []
        for block in kept {
            switch block.type {
            case "text":
                guard !block.text.isEmpty else { continue }
                content.append(.object(["type": .string("text"), "text": .string(block.text)]))
            case "tool_use":
                let id = block.start["id"]?.stringValue ?? ""
                let name = block.start["name"]?.stringValue ?? ""
                // Strict parse: eager input streaming means the API didn't validate this JSON.
                let json = block.partialJSON.isEmpty ? "{}" : block.partialJSON
                var parsed: [String: JSONValue]?
                if case .object(let object)? = JSONValue.parse(json) { parsed = object }
                toolUses.append((id, name, parsed))
                content.append(.object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": .object(parsed ?? [:])]))
            case "thinking":
                var object: [String: JSONValue] = ["type": .string("thinking"), "thinking": .string(block.thinking)]
                if let signature = block.signature { object["signature"] = .string(signature) }
                content.append(.object(object))
            case "fallback":
                continue
            default:
                content.append(.object(block.start)) // e.g. redacted_thinking: echo exactly as received
            }
        }
        return ClaudeTurn(content: content, text: kept.filter { $0.type == "text" }.map(\.text).joined(), toolUses: toolUses, stopReason: stopReason)
    }
}

// MARK: - Screen input

/// What Claude sees: a downscaled screenshot plus the OCR lines (for precise text ids).
public struct ScreenCapture: Sendable {
    public var promptBlock: String
    public var jpegBase64: String?
    /// Pixel size of the JPEG, the coordinate space for [POINT:x,y] and click x,y.
    public var imageSize: CGSize?

    public init(promptBlock: String, jpegBase64: String?, imageSize: CGSize?) {
        self.promptBlock = promptBlock
        self.jpegBase64 = jpegBase64
        self.imageSize = imageSize
    }

    func contentBlocks(caption: String) -> [JSONValue] {
        var blocks: [JSONValue] = []
        if let jpegBase64, let imageSize {
            blocks.append(.object(["type": .string("text"), "text": .string("Screenshot of the screen under the cursor (\(Int(imageSize.width))x\(Int(imageSize.height)) pixels):")]))
            blocks.append(.object(["type": .string("image"), "source": .object([
                "type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string(jpegBase64),
            ])]))
        }
        blocks.append(.object(["type": .string("text"), "text": .string(promptBlock + "\n\n" + caption)]))
        return blocks
    }
}

// MARK: - Loop

/// The Claude brain: answers questions and acts through the same tools and approval policy as the
/// local loop, but sees real screenshots (including after its own actions via read_screen).
public struct ClaudeAgentLoop: Sendable {
    public var client: AnthropicClient
    public var model: String
    public var effort: String
    public var executor: AgentExecutor
    public var maxSteps: Int
    public var policy: ApprovalPolicy
    /// Captures a fresh screen for read_screen.
    public var captureScreen: @Sendable () async -> ScreenCapture?

    public init(client: AnthropicClient, model: String, effort: String, executor: AgentExecutor, maxSteps: Int,
                policy: ApprovalPolicy, captureScreen: @escaping @Sendable () async -> ScreenCapture?) {
        self.client = client
        self.model = model
        self.effort = effort
        self.executor = executor
        self.maxSteps = maxSteps
        self.policy = policy
        self.captureScreen = captureScreen
    }

    public static var tools: [JSONValue] {
        AgentTools.definitions.compactMap { definition in
            guard case .object(let wrapper) = definition, case .object(let function)? = wrapper["function"] else { return nil }
            return .object([
                "name": function["name"] ?? .null,
                "description": function["description"] ?? .null,
                "input_schema": function["parameters"] ?? .null,
                "eager_input_streaming": .bool(true),
            ])
        }
    }

    /// Returns the final reply text ("" if stopped).
    @discardableResult
    public func run(
        request: String,
        screen: ScreenCapture?,
        history: [ChatMessage] = [],
        confirm: @Sendable (AgentAction) async -> AgentDecision,
        emit: @Sendable (AgentEvent) async -> Void
    ) async throws -> String {
        let system = Prompts.claude(workingDirectory: executor.workingDirectory, commandTimeout: Int(executor.timeout))
        var messages: [JSONValue] = history.map { .object(["role": .string($0.role.rawValue), "content": .string($0.content)]) }
        let userContent: JSONValue = screen.map { .array($0.contentBlocks(caption: request)) } ?? .string(request)
        messages.append(.object(["role": .string("user"), "content": userContent]))

        for _ in 0..<maxSteps {
            await emit(.turnStarted)
            let turn = try await client.streamTurn(model: model, effort: effort, system: system, tools: Self.tools, messages: messages) { text in
                await emit(.thinking(text))
            }
            try Task.checkCancellation()
            messages.append(.object(["role": .string("assistant"), "content": .array(turn.content)]))

            if turn.stopReason == "refusal" {
                let reply = "I can't help with that one."
                await emit(.finished(reply))
                return reply
            }
            if turn.toolUses.isEmpty || turn.stopReason == "max_tokens" {
                await emit(.finished(turn.text))
                return turn.text
            }

            var results: [JSONValue] = []
            for use in turn.toolUses {
                var result: [String: JSONValue] = ["type": .string("tool_result"), "tool_use_id": .string(use.id)]
                guard let input = use.input else {
                    result["content"] = .string("Error: the tool input wasn't valid JSON. Call the tool again.")
                    result["is_error"] = .bool(true)
                    results.append(.object(result))
                    continue
                }
                let action = AgentAction(call: ToolCall(name: use.name, arguments: input))
                var output: String
                if case .invalid = action {
                    output = await executor.execute(action)
                    result["is_error"] = .bool(true)
                    await emit(.output(action, output))
                } else if action.needsApproval(under: policy) {
                    await emit(.proposed(action))
                    switch await confirm(action) {
                    case .stop:
                        await emit(.stopped)
                        return ""
                    case .skip:
                        output = "The user declined this step. Don't retry it; choose another approach or finish."
                        await emit(.skipped(action))
                    case .run:
                        try Task.checkCancellation()
                        output = await executor.execute(action)
                        await emit(.output(action, output))
                    }
                } else {
                    await emit(.running(action))
                    if action == .readScreen, let capture = await captureScreen() {
                        await emit(.output(action, "Read the screen."))
                        result["content"] = .array(capture.contentBlocks(caption: "This is the screen now."))
                        results.append(.object(result))
                        continue
                    }
                    output = await executor.execute(action)
                    await emit(.output(action, output))
                }
                if output.hasPrefix("Error") { result["is_error"] = .bool(true) }
                result["content"] = .string(output)
                results.append(.object(result))
            }
            try Task.checkCancellation()
            messages.append(.object(["role": .string("user"), "content": .array(results)]))
        }
        let limit = "I stopped after \(maxSteps) steps without finishing. Try a narrower request."
        await emit(.finished(limit))
        return limit
    }
}
