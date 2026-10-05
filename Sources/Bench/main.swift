import CompanionCore
import Foundation

// Measures the local brain on everyday requests with ZOOBIE's real prompt, tools and loop.
// Actions are never executed: the run stops at the first tool call and records it.
//   swift run -c release Bench [--screen always|asked] [--budget chars] [model …]
//   swift run -c release Bench --dump    prints the exact system prompt and tools as JSON
//   swift run -c release Bench --agent jobs "task" [model]    one specialist task on the local model, live web

struct Scenario {
    var request: String
    /// The request is about the screen, so the screen text belongs in the prompt.
    var aboutScreen = false
    /// Acceptable first tools; empty means a spoken answer with no tool.
    var expect: Set<String>
    /// A spoken answer must mention one of these (case-insensitive).
    var mentions: [String] = []
}

let scenarios = [
    Scenario(request: "resume my music on spotify", expect: ["run_applescript", "media_control"]),
    Scenario(request: "next song", expect: ["media_control", "run_applescript"]),
    Scenario(request: "open safari", expect: ["open_app"]),
    Scenario(request: "set a timer for 10 minutes for pasta", expect: ["set_timer"]),
    Scenario(request: "remind me to call mom tomorrow at 6pm", expect: ["create_reminder"]),
    Scenario(request: "what's using port 3000?", expect: ["run_shell"]),
    Scenario(request: "what's the difference between a process and a thread?", expect: []),
    Scenario(request: "what's wrong with this code?", aboutScreen: true, expect: [], mentions: ["impot", "import"]),
    Scenario(request: "pause the music", expect: ["media_control", "run_applescript"]),
    Scenario(request: "set the volume to 30 percent", expect: ["run_applescript"]),
    Scenario(request: "what's on my calendar today?", expect: ["list_events"]),
    Scenario(request: "go to github.com in safari", expect: ["open_url", "run_applescript"]),
    Scenario(request: "make a file called notes.txt on my desktop that says buy milk", expect: ["write_file", "run_shell"]),
    Scenario(request: "how do I reverse a list in python?", expect: [], mentions: ["reverse", "[::-1]"]),
    Scenario(request: "ask Scrapeman to find software internships in Berlin", expect: ["delegate"]),
    Scenario(request: "Delegate this to the right specialist with the delegate tool: research the best 4K monitors under 500 euros", expect: ["delegate"]),
]

/// A realistic Xcode window: about 5,000 characters of OCR text, like a full screen of code. Each
/// request gets a slightly different one, as in real use, so the model can't reuse the last reading.
func screen(_ variant: Int) -> String {
    var lines = ["File Edit View Find Navigate Editor Product Debug Window Help", "ZOOBIE  main.swift  Build Failed  1 error  \(variant) min ago"]
    for n in 1...110 {
        lines.append(n == 12 ? "12  impot Foundation" : "\(n)  let value\(n) = try await client.fetch(\"item_\(n)\", retries: 3)")
    }
    lines.append("main.swift:12: error: cannot find 'impot' in scope")
    let elements = lines.enumerated().map { TextElement(id: $0.offset + 1, text: $0.element, frame: CGRect(x: 0, y: 2000 - $0.offset * 16, width: 600, height: 14)) }
    return ScreenContext(appName: "Xcode", windowTitle: "main.swift", elements: elements, cursor: CGPoint(x: 300, y: 1800)).promptBlock(budget: budget)
}

actor Recorder {
    let start = Date()
    var firstSentence: Double?
    var tool: (name: String, at: Double)?
    var text = ""
    var turns = 0

    var elapsed: Double { Date().timeIntervalSince(start) }

    func record(_ event: AgentEvent) {
        switch event {
        case .turnStarted:
            turns += 1
        case .thinking(let visible):
            text = visible
            if firstSentence == nil, !ReplyParsing.narration(from: visible, final: false).steps.isEmpty { firstSentence = elapsed }
        case .callStarted:
            // The app speaks the acknowledgement now, while the call is still being written.
            if firstSentence == nil, !ReplyParsing.narration(from: text, final: true).steps.isEmpty { firstSentence = elapsed }
        case .finished(let final):
            if !final.isEmpty { text = final }
            if firstSentence == nil, !ReplyParsing.narration(from: text, final: true).steps.isEmpty { firstSentence = elapsed }
        default:
            break
        }
    }

    func proposed(_ action: AgentAction) {
        if tool == nil { tool = (toolName(action), elapsed) }
    }
}

func toolName(_ action: AgentAction) -> String {
    switch action {
    case .openApp: "open_app"
    case .appleScript: "run_applescript"
    case .media: "media_control"
    case .click: "click"
    case .typeText: "type_text"
    case .pressKeys: "press_keys"
    case .readScreen: "read_screen"
    case .setTimer: "set_timer"
    case .listTimers: "list_timers"
    case .cancelTimer: "cancel_timer"
    case .createReminder: "create_reminder"
    case .listEvents: "list_events"
    case .createEvent: "create_event"
    case .shell: "run_shell"
    case .readFile: "read_file"
    case .writeFile: "write_file"
    case .listDirectory: "list_directory"
    case .openURL: "open_url"
    case .delegate: "delegate"
    case .webSearch: "web_search"
    default: "other"
    }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
func seconds(_ t: Double?) -> String { t.map { String(format: "%5.2fs", $0) } ?? "    — " }

var args = Array(CommandLine.arguments.dropFirst())
var screenMode = "always"
var budget = 6000
if let i = args.firstIndex(of: "--budget"), i + 1 < args.count, let value = Int(args[i + 1]) {
    budget = value
    args.removeSubrange(i...i + 1)
}
if let i = args.firstIndex(of: "--screen"), i + 1 < args.count {
    screenMode = args[i + 1]
    args.removeSubrange(i...i + 1)
}
if args.first == "--dump" {
    // The exact system prompt and tools the local brain sends, for replaying requests by hand.
    let executor = AgentExecutor(workingDirectory: "~", timeout: 5)
    let dump: JSONValue = .object(["system": .string(Prompts.assistant(workingDirectory: executor.workingDirectory, commandTimeout: 5)),
                                   "tools": .array(AgentLoop.tools)])
    print(String(decoding: try JSONEncoder().encode(dump), as: UTF8.self))
    exit(0)
}
let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!)
if args.first == "--agent", args.count >= 3, let id = Specialist.ID(rawValue: args[1]) {
    // Runs one specialist task on the local model with live web tools. Risky steps are skipped, never run.
    let model = args.count > 3 ? args[3] : "qwen2.5-coder:7b"
    let loop = AgentLoop(client: client, model: model, options: .init(numCtx: 8192, temperature: 0.3, keepAlive: "-1m"),
                         executor: AgentExecutor(workingDirectory: NSTemporaryDirectory(), timeout: 20), maxSteps: 12,
                         role: .specialist(Specialist.get(id), name: Specialist.get(id).defaultName, notebook: "", conversation: false))
    let start = Date()
    let report = try await loop.run(request: args[2], screen: nil, confirm: { action in
        print(String(format: "%6.1fs  skipped (needs approval): %@", Date().timeIntervalSince(start), action.title)); return .skip
    }, emit: { event in
        switch event {
        case .running(let action): print(String(format: "%6.1fs  ▸ %@: %@", Date().timeIntervalSince(start), action.title, String(action.detail.prefix(90))))
        case .output(_, let output): print("          ↳ \(output.split(separator: "\n").prefix(2).joined(separator: " | ").prefix(150))")
        default: break
        }
    })
    print(String(format: "\n%.1fs total. Report:\n", Date().timeIntervalSince(start)) + report)
    exit(0)
}
let installed = try await client.listModels()
let models = args.isEmpty ? ["qwen2.5-coder:7b"] : args

for model in models {
    let thinks = installed.first { $0.name == model }?.supportsThinking == true
    let options = OllamaClient.Options(numCtx: 8192, temperature: 0.2, keepAlive: "-1m", think: thinks ? false : nil)
    let loop = AgentLoop(client: client, model: model, options: options,
                         executor: AgentExecutor(workingDirectory: "~", timeout: 5), maxSteps: 3, policy: .always,
                         role: .assistant(specialistNames: [.jobs: "Scrapeman", .mentor: "KMan", .schedule: "Zoobs", .german: "Adolf"]))
    let primeStart = Date()
    let primed = await loop.prime() ?? 0 // loads the model too, with the same context size as the requests
    print("\n\(model) (screen: \(screenMode), \(budget) chars) — loaded and read the \(primed)-token prompt in \(seconds(Date().timeIntervalSince(primeStart)))")
    print("request                                   first words      action     total  turns  result")
    var passed = 0
    for (index, scenario) in scenarios.enumerated() {
        let recorder = Recorder()
        let screenText = screenMode == "always" || scenario.aboutScreen ? screen(index) : nil
        _ = try await loop.run(request: scenario.request, screen: screenText,
                               confirm: { await recorder.proposed($0); return .stop },
                               emit: { await recorder.record($0) })
        let total = await recorder.elapsed
        let tool = await recorder.tool
        let said = await recorder.text.replacingOccurrences(of: "\n", with: " ")
        let mentioned = scenario.mentions.isEmpty || scenario.mentions.contains { said.localizedCaseInsensitiveContains($0) }
        let ok = scenario.expect.isEmpty ? tool == nil && mentioned : tool.map { scenario.expect.contains($0.name) } ?? false
        if ok { passed += 1 }
        print("\(pad(scenario.request, 42))  \(seconds(await recorder.firstSentence))       \(seconds(tool?.at))  \(seconds(total))  \(await recorder.turns)      \(ok ? "✓" : "✗") \(tool?.name ?? "speech"): \(said.prefix(60))")
    }
    print("\(passed)/\(scenarios.count) correct")
}
