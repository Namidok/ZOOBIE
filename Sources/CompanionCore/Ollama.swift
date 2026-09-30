import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

public struct ToolCall: Codable, Sendable, Equatable {
    public struct Function: Codable, Sendable, Equatable {
        public var name: String
        public var arguments: [String: JSONValue]

        public init(name: String, arguments: [String: JSONValue]) {
            self.name = name
            self.arguments = arguments
        }

        private enum CodingKeys: String, CodingKey { case name, arguments }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            // Arguments arrive as an object, but some models emit a JSON-encoded string instead.
            if let object = try? c.decode([String: JSONValue].self, forKey: .arguments) {
                arguments = object
            } else if let text = try? c.decode(String.self, forKey: .arguments),
                      case .object(let object)? = JSONValue.parse(text) {
                arguments = object
            } else {
                arguments = [:]
            }
        }
    }

    public var function: Function

    public init(name: String, arguments: [String: JSONValue]) {
        function = Function(name: name, arguments: arguments)
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: ChatRole
    public var content: String
    /// Base64-encoded images, only honoured by vision models.
    public var images: [String]?
    public var toolCalls: [ToolCall]?
    public var toolName: String?

    public init(role: ChatRole, content: String, images: [String]? = nil, toolCalls: [ToolCall]? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, images
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(ChatRole.self, forKey: .role) ?? .assistant
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        images = try c.decodeIfPresent([String].self, forKey: .images)
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
    }
}

/// One NDJSON line of a streaming /api/chat response.
public struct ChatChunk: Decodable, Sendable {
    public var message: ChatMessage?
    public var done: Bool
    public var error: String?

    private enum CodingKeys: String, CodingKey { case message, done, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decodeIfPresent(ChatMessage.self, forKey: .message)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct ModelInfo: Decodable, Sendable, Equatable {
    public var name: String
    public var capabilities: [String]

    public var supportsVision: Bool { capabilities.contains("vision") }
    public var supportsTools: Bool { capabilities.contains("tools") }
    public var supportsThinking: Bool { capabilities.contains("thinking") }

    public init(name: String, capabilities: [String]) {
        self.name = name
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey { case name, capabilities }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }
}

public enum OllamaError: LocalizedError {
    case unreachable(URL, underlying: Error)
    case http(Int, String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let url, _):
            return "Ollama isn't reachable at \(url.absoluteString). Start it with `ollama serve`."
        case .http(let code, let body):
            return "Ollama returned HTTP \(code): \(body)"
        case .server(let message):
            return "Ollama error: \(message)"
        }
    }
}

/// Minimal client for the local Ollama HTTP API. Nothing here talks to anything but `baseURL`.
public final class OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public func listModels() async throws -> [ModelInfo] {
        struct Tags: Decodable { var models: [ModelInfo] }
        let (data, response) = try await send(URLRequest(url: baseURL.appendingPathComponent("api/tags")))
        try Self.check(response, data)
        return try JSONDecoder().decode(Tags.self, from: data).models
    }

    /// Loads a model into memory ahead of the first question so first-token latency stays low.
    public func warmUp(model: String, keepAlive: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["model": model, "keep_alive": keepAlive])
        _ = try? await send(request)
    }

    public struct Options: Sendable {
        public var numCtx: Int
        public var temperature: Double
        public var keepAlive: String
        /// Only sent for models advertising the "thinking" capability; false keeps qwen3 fast.
        public var think: Bool?

        public init(numCtx: Int = 8192, temperature: Double = 0.2, keepAlive: String = "30m", think: Bool? = nil) {
            self.numCtx = numCtx
            self.temperature = temperature
            self.keepAlive = keepAlive
            self.think = think
        }
    }

    /// Streams a chat completion. Cancel the consuming task to abort generation.
    public func chat(model: String, messages: [ChatMessage], tools: [JSONValue]? = nil, options: Options) -> AsyncThrowingStream<ChatChunk, Error> {
        struct Body: Encodable {
            var model: String
            var messages: [ChatMessage]
            var stream = true
            var tools: [JSONValue]?
            var options: [String: JSONValue]
            var keep_alive: String
            var think: Bool?
        }
        let body = Body(
            model: model,
            messages: messages,
            tools: tools,
            options: ["num_ctx": .number(Double(options.numCtx)), "temperature": .number(options.temperature)],
            keep_alive: options.keepAlive,
            think: options.think
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)

        let session = self.session
        let baseURL = self.baseURL
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch {
                        throw OllamaError.unreachable(baseURL, underlying: error)
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw OllamaError.http(http.statusCode, Self.errorMessage(in: body) ?? body)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                        let chunk = try decoder.decode(ChatChunk.self, from: data)
                        if let error = chunk.error { throw OllamaError.server(error) }
                        continuation.yield(chunk)
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw OllamaError.unreachable(baseURL, underlying: error)
        }
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        let body = String(decoding: data, as: UTF8.self)
        throw OllamaError.http(http.statusCode, errorMessage(in: body) ?? body)
    }

    private static func errorMessage(in body: String) -> String? {
        guard case .object(let o)? = JSONValue.parse(body) else { return nil }
        return o["error"]?.stringValue
    }
}
