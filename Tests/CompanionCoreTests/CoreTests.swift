import CoreGraphics
import Foundation
import Testing
@testable import CompanionCore

@Suite struct ConfigTests {
    @Test func missingKeysFallBackToDefaults() throws {
        let json = #"{"chatModel": "qwen3:8b", "speakReplies": false}"#
        let config = try JSONDecoder().decode(CompanionConfig.self, from: Data(json.utf8))
        #expect(config.chatModel == "qwen3:8b")
        #expect(config.speakReplies == false)
        #expect(config.voice == "af_heart")
        #expect(config.keepAlive == "-1m")
        #expect(config.captionsAtCursor) // replies next to the cursor, like Clicky
        #expect(config.approvalPolicy == .risky)
        #expect(config.visionMode == .auto)
        #expect(config.ollamaURL.absoluteString == "http://127.0.0.1:11434")
    }

    @Test func roundTrips() throws {
        var config = CompanionConfig()
        config.visionModel = "qwen2.5vl:7b"
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(CompanionConfig.self, from: data) == config)
    }
}

@Suite struct OllamaDecodingTests {
    @Test func decodesStreamingChunkWithToolCall() throws {
        let line = #"{"model":"qwen2.5-coder:7b","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"run_shell","arguments":{"command":"ls -la"}}}]},"done":false}"#
        let chunk = try JSONDecoder().decode(ChatChunk.self, from: Data(line.utf8))
        #expect(chunk.done == false)
        #expect(chunk.message?.toolCalls?.first?.function.name == "run_shell")
        #expect(chunk.message?.toolCalls?.first?.function.arguments["command"] == .string("ls -la"))
    }

    @Test func decodesStringEncodedArguments() throws {
        let json = #"{"function":{"name":"read_file","arguments":"{\"path\":\"/tmp/a.txt\"}"}}"#
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
        #expect(call.function.arguments["path"] == .string("/tmp/a.txt"))
    }

    @Test func encodesToolMessageWithSnakeCaseKeys() throws {
        let message = ChatMessage(role: .tool, content: "ok", toolName: "run_shell")
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(json.contains(#""tool_name":"run_shell""#))
        #expect(!json.contains("images"))
    }

    @Test func modelCapabilities() throws {
        let json = #"{"name":"qwen2.5vl:7b","capabilities":["completion","vision"]}"#
        let model = try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
        #expect(model.supportsVision)
        #expect(!model.supportsTools)
    }
}

@Suite struct ReplyParsingTests {
    @Test func extractsAndStripsPointTag() {
        let (clean, point) = ReplyParsing.extractPoint(from: "Click the Run button. [POINT:12:Run]")
        #expect(clean == "Click the Run button.")
        #expect(point == PointTag(elementID: 12, label: "Run"))
    }

    @Test func extractsCoordinatePoints() {
        let (clean, points) = ReplyParsing.extractPoints(from: "That's the inspector [POINT:1100,42:color inspector:screen2].")
        #expect(clean == "That's the inspector.")
        #expect(points == [PointTag(x: 1100, y: 42, label: "color inspector")])
    }

    @Test func ignoresNonNumericPoint() {
        let (clean, point) = ReplyParsing.extractPoint(from: "Nothing to point at. [POINT:none]")
        #expect(clean == "Nothing to point at.")
        #expect(point == nil)
    }

    @Test func narrationSplitsSentencesWithPointsAndCode() {
        let reply = """
        The build fails because **Foundation** is misspelled on line 12 [POINT:7]. Fix the import, then rebuild with `swift build`.
        ```swift
        import Foundation
        ```
        """
        let narration = ReplyParsing.narration(from: reply, final: true)
        #expect(narration.steps == [
            NarrationStep(text: "The build fails because Foundation is misspelled on line 12.", points: [PointTag(elementID: 7)]),
            NarrationStep(text: "Fix the import, then rebuild with swift build."),
        ])
        #expect(narration.code == [CodeSnippet(language: "swift", code: "import Foundation")])
    }

    @Test func narrationAttachesTrailingTagToPreviousSentence() {
        let narration = ReplyParsing.narration(from: "Click Run. [POINT:3] Then open the console [POINT:9].", final: true)
        #expect(narration.steps.map(\.points) == [[PointTag(elementID: 3)], [PointTag(elementID: 9)]])
        #expect(narration.steps.map(\.text) == ["Click Run.", "Then open the console."])
    }

    @Test func streamingKeepsTrailingCoordinateTag() {
        let full = "Open the inspector. [POINT:1100,42:inspector] Then pick a color."
        var steps: [NarrationStep] = []
        for end in full.indices { steps = ReplyParsing.narration(from: String(full[..<end]), final: false).steps }
        #expect(steps.first?.points == [PointTag(x: 1100, y: 42, label: "inspector")])
    }

    @Test func narrationKeepsFileNamesWhole() {
        let steps = ReplyParsing.narration(from: "Open summary.txt in the editor. Done.", final: true).steps
        #expect(steps.map(\.text) == ["Open summary.txt in the editor.", "Done."])
    }

    @Test func streamingNarrationOnlyEmitsSettledSentences() {
        let full = "First click Run. [POINT:3] Then check the console [POINT:9]. That's it.\n```bash\nls\n```"
        var previous: [NarrationStep] = []
        // Feed every prefix, as a stream would: steps must only grow and never change.
        for end in full.indices {
            let steps = ReplyParsing.narration(from: String(full[..<end]), final: false).steps
            #expect(steps.count >= previous.count)
            #expect(Array(steps.prefix(previous.count)) == previous)
            previous = steps
        }
        let final = ReplyParsing.narration(from: full, final: true)
        #expect(Array(final.steps.prefix(previous.count)) == previous)
        #expect(final.steps.map(\.text) == ["First click Run.", "Then check the console.", "That's it."])
        #expect(final.steps.first?.points == [PointTag(elementID: 3)])
        #expect(final.code == [CodeSnippet(language: "bash", code: "ls")])
    }

    @Test func firstSentenceSpeaksItsOpeningClauseEarly() {
        let full = "A process is a running program, with its own memory. Threads share it, though."
        var previous: [NarrationStep] = []
        for end in full.indices {
            let steps = ReplyParsing.narration(from: String(full[..<end]), final: false).steps
            #expect(Array(steps.prefix(previous.count)) == previous)
            previous = steps
        }
        let steps = ReplyParsing.narration(from: full, final: true).steps.map(\.text)
        // Only the first sentence splits, and only after four or more words.
        #expect(steps == ["A process is a running program,", "with its own memory.", "Threads share it, though."])
        #expect(ReplyParsing.narration(from: "Sure, done.", final: true).steps.map(\.text) == ["Sure, done."])
        // The opening clause is ready as soon as the next word starts.
        #expect(ReplyParsing.narration(from: "A process is a running program, w", final: false).steps.map(\.text) == ["A process is a running program,"])
    }

    @Test func narrationReadsNumberedListsNaturally() {
        let steps = ReplyParsing.narration(from: "Here's how:\n1. Open your terminal.\n2. Run the command.", final: true).steps
        #expect(steps.map(\.text) == ["Here's how:", "Open your terminal.", "Run the command."])
    }

    @Test func narrationWithoutProseStillReturnsCode() {
        let narration = ReplyParsing.narration(from: "```\nls -la\n```", final: true)
        #expect(narration.steps.isEmpty)
        #expect(narration.code.count == 1)
    }
}

@Suite struct ScreenContextTests {
    private func raw(_ text: String, x: CGFloat, y: CGFloat) -> (text: String, frame: CGRect) {
        (text, CGRect(x: x, y: y, width: CGFloat(text.count) * 7, height: 14))
    }

    @Test func ordersTopToBottomLeftToRight() {
        let elements = ScreenContext.orderedElements([
            raw("bottom", x: 0, y: 100),
            raw("top-right", x: 300, y: 500),
            raw("top-left", x: 10, y: 502),
        ])
        #expect(elements.map(\.text) == ["top-left", "top-right", "bottom"])
        #expect(elements.map(\.id) == [1, 2, 3])
    }

    @Test func trimsToLinesNearestCursor() {
        let lines = (0..<100).map { raw(String(repeating: "x", count: 50) + " line\($0)", x: 0, y: CGFloat(2000 - $0 * 20)) }
        let context = ScreenContext(appName: "Xcode", windowTitle: "main.swift", elements: ScreenContext.orderedElements(lines), cursor: CGPoint(x: 10, y: 1000))
        let block = context.promptBlock(budget: 600)
        #expect(block.hasPrefix("<screen app=\"Xcode\" window=\"main.swift\" trimmed="))
        #expect(block.contains("line50"))
        #expect(!block.contains("line0\n"))
        #expect(!block.contains("line99"))
    }

    @Test func visionRouting() {
        #expect(VisionRouting.shouldUseVision(mode: .auto, hasVisionModel: true, ocrCharacters: 20, question: "what's this"))
        #expect(VisionRouting.shouldUseVision(mode: .auto, hasVisionModel: true, ocrCharacters: 5000, question: "does this layout look right?"))
        #expect(!VisionRouting.shouldUseVision(mode: .auto, hasVisionModel: true, ocrCharacters: 5000, question: "fix this error"))
        #expect(!VisionRouting.shouldUseVision(mode: .always, hasVisionModel: false, ocrCharacters: 0, question: "look"))
    }

    @Test func screenRoutingReadsTheScreenOnlyWhenAsked() {
        for request in ["why won't this build?", "fix this error", "what's on my screen", "summarise this page", "Explain the selected code"] {
            #expect(ScreenRouting.refersToScreen(request), "\(request)")
        }
        for request in ["next song", "resume my music on spotify", "open safari", "set a timer for 10 minutes",
                        "remind me to call mom tomorrow at 6pm", "what's using port 3000?", "what's a closure in swift?"] {
            #expect(!ScreenRouting.refersToScreen(request), "\(request)")
        }
    }
}

@Suite struct AgentTests {
    @Test func detectsACallBeingWrittenButNotBracesInProse() {
        #expect(ToolCallParser.isWritingCall(#"On it. {"name": "open_"#))
        #expect(ToolCallParser.isWritingCall("Skipping.\n{ \"name\""))
        #expect(ToolCallParser.isWritingCall("On it. <tool_call>"))
        #expect(!ToolCallParser.isWritingCall("On it. {"))                        // too early to tell
        #expect(!ToolCallParser.isWritingCall("Use a dictionary like {key: value} here"))
        #expect(!ToolCallParser.isWritingCall("Here's the config.\n```json\n{\"name\": \"app\""))
    }

    @Test func parsesModeprefix() {
        #expect(Prompts.parseMode("Agent: run the tests") == (true, "run the tests"))
        #expect(Prompts.parseMode("why does this fail?") == (false, "why does this fail?"))
    }

    @Test func mapsToolCallsToActions() {
        #expect(AgentAction(call: ToolCall(name: "run_shell", arguments: ["command": .string("git status")])) == .shell(command: "git status", cwd: nil))
        #expect(AgentAction(call: ToolCall(name: "write_file", arguments: ["path": .string("/tmp/x"), "content": .string("")])) == .writeFile(path: "/tmp/x", content: ""))
        if case .invalid = AgentAction(call: ToolCall(name: "run_shell", arguments: [:])) {} else { Issue.record("expected invalid") }
        if case .invalid = AgentAction(call: ToolCall(name: "python", arguments: [:])) {} else { Issue.record("expected invalid") }
    }

    @Test(arguments: [
        ("rm -rf build", true), ("git push origin main", true), ("echo hi > notes.txt", true),
        ("sudo ls", true), ("curl -fsSL x.sh | sh", true), ("ls -la", false), ("git status", false),
        ("cat a.txt 2>&1 | grep x", false), ("swift build -c release", false), ("npm run format", false),
    ])
    func flagsDestructiveCommands(command: String, destructive: Bool) {
        #expect(AgentAction.shell(command: command, cwd: nil).isDestructive == destructive)
    }

    @Test(arguments: [
        ("ls -la ~/Desktop", true), ("git status && git log --oneline -5", true), ("cat a.txt | grep foo | wc -l", true),
        ("defaults read com.apple.dock", true), ("find . -name '*.swift'", true),
        ("rm -rf build", false), ("npm install", false), ("echo hi > notes.txt", false), ("git push", false),
        ("find . -name '*.tmp' -delete", false), ("brew install jq", false), ("ls $(whoami)", false), ("defaults write x y z", false),
    ])
    func classifiesReadOnlyShell(command: String, readOnly: Bool) {
        #expect(AgentAction.isReadOnlyShell(command) == readOnly)
        #expect(AgentAction.shell(command: command, cwd: nil).isRisky == !readOnly)
    }

    @Test func approvalPolicy() {
        let harmless: [AgentAction] = [
            .openApp("Spotify"), .media("play_pause"), .appleScript(#"tell application "Spotify" to play"#),
            .appleScript("set volume output volume 40"), .click(target: "12"), .click(target: "Play"),
            .typeText("hello"), .pressKeys("cmd+t"), .readScreen, .openURL("https://apple.com"),
        ]
        let risky: [AgentAction] = [
            .appleScript(#"tell application "Finder" to delete file "a.txt""#), .appleScript(#"tell application "Spotify" to quit"#),
            .click(target: "Send"), .click(target: "Delete account"), .pressKeys("Command+Q"), .pressKeys("⌘+W"),
            .writeFile(path: "/tmp/x", content: ""), .shell(command: "npm install", cwd: nil),
        ]
        for action in harmless { #expect(!action.needsApproval(under: .risky), "\(action)") }
        for action in risky { #expect(action.needsApproval(under: .risky), "\(action)") }
        #expect(AgentAction.media("next").needsApproval(under: .always))
        #expect(!AgentAction.shell(command: "rm -rf /tmp/x", cwd: nil).needsApproval(under: .never))
    }

    @Test func rejectsPlaceholderPaths() {
        for command in ["cd /path/to/your/project && pip install flask", "ls /Users/username/Desktop", "cat <your-file>"] {
            if case .invalid = AgentAction(call: ToolCall(name: "run_shell", arguments: ["command": .string(command)])) {} else {
                Issue.record("expected placeholder rejection for \(command)")
            }
        }
        #expect(AgentAction(call: ToolCall(name: "run_shell", arguments: ["command": .string("ls ~/Desktop")])) == .shell(command: "ls ~/Desktop", cwd: nil))
    }

    @Test func explainsAutomationDenial() {
        let message = AgentExecutor.explainAppleScriptError("execution error: Not authorized to send Apple events to Spotify. (-1743)")
        #expect(message.contains("Privacy & Security > Automation"))
    }

    @Test func accumulatesStreamedClaudeTurn() {
        var accumulator = TurnAccumulator()
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Resuming your music."}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_applescript","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"script\": \"tell application"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" \\\"Spotify\\\" to play\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]
        for event in events {
            guard case .object(let object)? = JSONValue.parse(event) else { Issue.record("bad fixture \(event)"); return }
            _ = accumulator.apply(object)
        }
        let turn = accumulator.turn()
        #expect(turn.text == "Resuming your music.")
        #expect(turn.stopReason == "tool_use")
        #expect(turn.toolUses.first?.name == "run_applescript")
        #expect(turn.toolUses.first?.input?["script"] == .string(#"tell application "Spotify" to play"#))
        #expect(turn.content.count == 3) // thinking (with signature) is echoed back unchanged
        if case .object(let thinking) = turn.content[0] { #expect(thinking["signature"] == .string("sig")) }
    }

    @Test func claudeToolsUseAnthropicShape() {
        let tools = ClaudeAgentLoop.tools(for: .assistant)
        #expect(tools.count == AgentTools.names.count - AgentTools.specialistOnly.count - AgentTools.localOnly.count + 2) // + Claude's two server web tools // + web_search, web_fetch
        guard case .object(let first)? = tools.first else { Issue.record("no tools"); return }
        #expect(first["input_schema"] != nil)
        #expect(first["eager_input_streaming"] == .bool(true))
    }

    @Test func specialistsGetOnlyTheirTools() {
        func names(_ role: ClaudeAgentLoop.Role) -> Set<String> {
            Set(ClaudeAgentLoop.tools(for: role).compactMap { tool -> String? in
                guard case .object(let object) = tool else { return nil }
                return object["name"]?.stringValue
            })
        }
        for specialist in Specialist.all {
            let tools = names(.specialist(specialist, name: specialist.defaultName, notebook: "", conversation: false))
            #expect(tools.contains("web_search") && tools.contains("update_notebook"))
            for name in AgentTools.foregroundOnly { #expect(!tools.contains(name), "\(specialist.id): \(name)") }
        }
        let scheduler = names(.specialist(Specialist.get(.schedule), name: "x", notebook: "", conversation: false))
        #expect(scheduler.contains("set_timer") && scheduler.contains("create_event") && !scheduler.contains("run_shell"))
        let assistant = names(.assistant)
        #expect(assistant.contains("delegate") && assistant.contains("set_timer") && !assistant.contains("update_notebook"))
        let worker = ClaudeAgentLoop.Role.specialist(Specialist.get(.jobs), name: "x", notebook: "", conversation: false)
        guard case .object(let search)? = ClaudeAgentLoop.tools(for: worker).first(where: {
            if case .object(let o) = $0 { return o["name"] == .string("web_search") } else { return false }
        }) else { Issue.record("no web_search"); return }
        #expect(search["eager_input_streaming"] == nil) // only valid on client tools
    }

    @Test func agentRunsPersistAndActiveOnesComeBackCancelled() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zoobie-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AgentRunStore(directory: base.appendingPathComponent("runs"), reportsDirectory: base.appendingPathComponent("reports"))
        var done = AgentRun(title: "Monitors", task: "Find 4K monitors")
        done.status = .done
        done.report = "**The Dell U2723QE** is the best pick.\n\nDetails…"
        done.reportPath = store.writeReport(done.report!, for: done)
        store.save(done)
        store.save(AgentRun(title: "Still going", task: "x"))
        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded.first { $0.title == "Still going" }?.status == .cancelled)
        #expect(loaded.first { $0.title == "Monitors" }?.summary == "The Dell U2723QE is the best pick.")
        #expect(try String(contentsOfFile: done.reportPath!, encoding: .utf8).contains("# Monitors"))
    }

    @Test func onlyRealReportsGetAFile() {
        #expect(!AgentRunStore.deservesFile("I'm sorry to hear that. Is there anything you'd like to talk about?"))
        #expect(!AgentRunStore.deservesFile(""))
        #expect(AgentRunStore.deservesFile(String(repeating: "Internship at Siemens, Munich: apply by Nov 1. ", count: 20)))
    }

    @Test func calendarScriptsUseStructuredDates() throws {
        let start = try #require(LocalDate.parse("2026-10-02T18:30"))
        let script = AppleAppScripts.createEvent(title: "Submit \"DSA\" A3", start: start, end: start.addingTimeInterval(3600), location: nil)
        #expect(script.contains("set year of startDate to 2026"))
        #expect(script.contains("set month of startDate to 10"))
        #expect(script.contains("set time of startDate to 66600")) // 18:30
        #expect(script.contains(#"summary:"Submit \"DSA\" A3""#))
        #expect(LocalDate.parse("2026-10-02") != nil && LocalDate.parse("next friday") == nil)
    }

    @Test func specialistMemoryPersists() {
        let store = SpecialistStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("zoobie-spec-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try? "# Level: A2".write(to: store.notebookURL(.german), atomically: true, encoding: .utf8)
        store.append([ChatMessage(role: .user, content: "Hallo"), ChatMessage(role: .assistant, content: "Hallo! Wie geht's?")], to: .german)
        #expect(store.notebook(.german) == "# Level: A2")
        #expect(store.thread(.german).count == 2)
        store.clear(.german)
        #expect(store.thread(.german).isEmpty && store.notebook(.german).isEmpty)
        #expect(Specialist.resolve("Deutsch tutor")?.id == .german && Specialist.resolve("resume helper")?.id == .jobs)
    }

    @Test func parsesNewTools() {
        #expect(AgentAction(call: ToolCall(name: "open_app", arguments: ["name": .string("Spotify")])) == .openApp("Spotify"))
        #expect(AgentAction(call: ToolCall(name: "media_control", arguments: ["command": .string("Play_Pause")])) == .media("play_pause"))
        #expect(AgentAction(call: ToolCall(name: "click", arguments: ["target": .number(12)])) == .click(target: "12"))
        #expect(AgentAction(call: ToolCall(name: "read_screen", arguments: [:])) == .readScreen)
        #expect(AgentAction(call: ToolCall(name: "delegate", arguments: ["agent": .string("Job Hunter"), "title": .string("Internships"), "task": .string("Find internships")])) == .delegate(agent: .jobs, title: "Internships", task: "Find internships"))
        #expect(AgentAction(call: ToolCall(name: "talk_to", arguments: ["agent": .string("german")])) == .talkTo(.german))
        #expect(AgentAction(call: ToolCall(name: "set_timer", arguments: ["minutes": .number(25), "label": .string("Focus")])) == .setTimer(seconds: 1500, label: "Focus"))
        #expect(AgentAction(call: ToolCall(name: "set_timer", arguments: ["minutes": .string("0.5")])) == .setTimer(seconds: 30, label: "Timer"))
        if case .invalid = AgentAction(call: ToolCall(name: "create_event", arguments: ["title": .string("x"), "start": .string("tomorrow 6pm")])) {} else { Issue.record("expected invalid date") }
        if case .invalid = AgentAction(call: ToolCall(name: "media_control", arguments: ["command": .string("louder")])) {} else { Issue.record("expected invalid") }
        #expect(AgentAction.normalizedKeys("Shift + Command + T") == "shift+cmd+t")
    }

    @Test func recoversToolCallFromTaggedContent() {
        let content = """
        I'll check the repo state first.
        <tool_call>
        {"name": "run_shell", "arguments": {"command": "git status"}}
        </tool_call>
        """
        let calls = ToolCallParser.fallbackCalls(in: content)
        #expect(calls == [ToolCall(name: "run_shell", arguments: ["command": .string("git status")])])
        #expect(ToolCallParser.strippingCalls(content) == "I'll check the repo state first.")
    }

    @Test func recoversToolCallFromJSONFence() {
        let content = "```json\n{\"name\": \"list_directory\", \"arguments\": {\"path\": \"~/Desktop\"}}\n```"
        #expect(ToolCallParser.fallbackCalls(in: content).first?.function.name == "list_directory")
        #expect(ToolCallParser.strippingCalls(content) == "")
    }

    @Test func recoversBareJSONAfterProse() {
        // Exactly what qwen2.5-coder:7b emits through Ollama.
        let content = "Plan: count the files.\n\n{\"name\": \"list_directory\", \"arguments\": {\"path\": \"/tmp/a {b}\"}}"
        #expect(ToolCallParser.fallbackCalls(in: content) == [ToolCall(name: "list_directory", arguments: ["path": .string("/tmp/a {b}")])])
        #expect(ToolCallParser.strippingCalls(content) == "Plan: count the files.")
    }

    @Test func hidesCallWhileStreaming() {
        let partial = "Plan: count the files.\n\n{\"name\": \"list_dir"
        #expect(ToolCallParser.strippingCalls(partial) == "Plan: count the files.")
        #expect(ToolCallParser.strippingCalls("On it. {\"") == "On it.")
        #expect(ToolCallParser.strippingCalls("Try this:\n```swift\nfunc a() {") == "Try this:\n```swift\nfunc a() {")
        #expect(ToolCallParser.fallbackCalls(in: partial).isEmpty)
    }

    @Test(arguments: [
        ("There are 2 .txt files in the directory. Writing the count to summary.txt.", true),
        ("Found the config. I'll update the port next.", true),
        ("Let me check the logs", true),
        ("Resuming your music.", true),
        ("Your music is playing. Let me know if you need anything else.", false),
        ("Created summary.txt containing 2.", false),
        ("The tests pass. Nothing else to change.", false),
        ("Done — the server is now running on port 3000.", false),
    ])
    func detectsNarratedButUncalledSteps(text: String, pending: Bool) {
        #expect(AgentLoop.announcesPendingStep(text) == pending)
    }

    @Test func ignoresOrdinaryJSONInReply() {
        let content = "Your package.json should contain:\n```json\n{\"name\": \"my-app\", \"version\": \"1.0.0\"}\n```"
        #expect(ToolCallParser.fallbackCalls(in: content).isEmpty)
        #expect(ToolCallParser.strippingCalls(content) == content)
    }

    @Test func executesShellWithExitCodeAndTimeout() async {
        let executor = AgentExecutor(workingDirectory: NSTemporaryDirectory(), timeout: 1)
        let ok = await executor.execute(.shell(command: "echo hello; exit 3", cwd: nil))
        #expect(ok == "hello\n[exit code 3]")
        let slow = await executor.execute(.shell(command: "sleep 5", cwd: nil))
        #expect(slow.hasSuffix("[timed out after 1s]"))
    }

    @Test func writesReadsAndListsFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("companion-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = AgentExecutor(workingDirectory: dir.path, timeout: 5)
        _ = await executor.execute(.writeFile(path: "sub/note.txt", content: "hi"))
        #expect(await executor.execute(.readFile(path: dir.appendingPathComponent("sub/note.txt").path)) == "hi")
        #expect(await executor.execute(.listDirectory(path: ".")) == "sub/")
    }
}

/// Hits the local Ollama server. Run with: COMPANION_LIVE=1 scripts/test.sh --filter LiveOllamaTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COMPANION_LIVE"] == "1"), .serialized)
struct LiveOllamaTests {
    let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!)
    let model = ProcessInfo.processInfo.environment["COMPANION_MODEL"] ?? "qwen2.5-coder:7b"

    @Test func streamsChatReply() async throws {
        let start = Date()
        var firstToken: TimeInterval?
        var reply = ""
        let messages = [ChatMessage(role: .system, content: Prompts.interactive(hasImage: false)),
                        ChatMessage(role: .user, content: "<screen app=\"Terminal\">\n[1] zsh: command not found: pyhton\n</screen>\n\nwhat went wrong?")]
        for try await chunk in client.chat(model: model, messages: messages, options: .init()) {
            if firstToken == nil, chunk.message?.content.isEmpty == false { firstToken = Date().timeIntervalSince(start) }
            reply += chunk.message?.content ?? ""
        }
        print("first token after \(String(format: "%.2f", firstToken ?? -1))s, total \(String(format: "%.2f", Date().timeIntervalSince(start)))s\n\(reply)")
        print("spoken:", ReplyParsing.narration(from: reply, final: true).steps.map(\.text))
        #expect(reply.lowercased().contains("python"))
    }

    @Test func narratesWithPointsForGuidance() async throws {
        let screen = """
        <screen app="Code" window="app.py — demo">
        [1] File  Edit  Selection  View  Run  Terminal
        [2] EXPLORER
        [3] app.py
        [4] requirements.txt
        [5] import flask
        [6] app = flask.Flask(__name__)
        [7] Run Python File
        [8] PROBLEMS  OUTPUT  TERMINAL
        [9] ModuleNotFoundError: No module named 'flask'
        </screen>
        """
        // The app's main path: the tool-using assistant. Actions are recorded and declined.
        let loop = AgentLoop(client: client, model: model, options: .init(),
                             executor: AgentExecutor(workingDirectory: NSTemporaryDirectory(), timeout: 5), maxSteps: 2, policy: .always)
        let reply = try await loop.run(request: "what's that error about?", screen: screen,
                                       confirm: { action in print("ACTION:", action.title, action.detail); return .skip },
                                       emit: { _ in })
        let narration = ReplyParsing.narration(from: reply, final: true)
        print("RAW:\n\(reply)\n---")
        for step in narration.steps { print("SAY:", step.text, "POINTS:", step.points.map(\.elementID)) }
        for code in narration.code { print("CODE[\(code.language)]:", code.code) }
        #expect(!narration.steps.isEmpty)
    }

    @Test(arguments: ["open spotify and resume the music", "pause whatever is playing", "open safari"])
    func actsInsteadOfExplaining(request: String) async throws {
        // Policy .always + skip: every action is proposed and recorded, none is executed.
        let loop = AgentLoop(client: client, model: model, options: .init(),
                             executor: AgentExecutor(workingDirectory: NSTemporaryDirectory(), timeout: 5), maxSteps: 2, policy: .always)
        let log = EventLog()
        let final = try await loop.run(
            request: request, screen: nil,
            confirm: { action in await log.add("ACTION \(action.title): \(action.detail)"); return .skip },
            emit: { event in if case .thinking(let text) = event { await log.add("SAY \(text)") } }
        )
        let lines = await log.lines
        for line in lines { print(line) }
        print("FINAL:", final)
        #expect(lines.contains { $0.hasPrefix("ACTION") })
    }

    @Test func agentCompletesTaskWithApprovedSteps() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("companion-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "b.txt", "c.md"] { try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        let loop = AgentLoop(client: client, model: model, options: .init(), executor: AgentExecutor(workingDirectory: dir.path, timeout: 20), maxSteps: 6)
        let log = EventLog()
        try await loop.run(
            request: "Create a file named summary.txt in \(dir.path) whose content is the number of .txt files in that directory.",
            screen: nil,
            confirm: { action in await log.add("confirm: \(action.title) — \(action.detail)"); return .run },
            emit: { event in await log.add("\(event)") }
        )
        for line in await log.lines { print(line) }
        let summary = try? String(contentsOf: dir.appendingPathComponent("summary.txt"), encoding: .utf8)
        #expect(summary?.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }
}

private actor EventLog {
    var lines: [String] = []
    /// Streaming `thinking` events replace each other, so keep only the latest per turn.
    func add(_ line: String) {
        if line.hasPrefix("thinking("), lines.last?.hasPrefix("thinking(") == true { lines.removeLast() }
        lines.append(String(line.prefix(400)))
    }
}

/// Serves a canned SSE stream and records the request, so the wire format is checked without a key.
final class MockAnthropicProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequestBody: JSONValue?
    nonisolated(unsafe) static var lastHeaders: [String: String] = [:]
    nonisolated(unsafe) static var responseStream = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            body = data
        }
        Self.lastRequestBody = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseStream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ClaudeWireTests {
    @Test func sendsCorrectRequestAndParsesStream() async throws {
        MockAnthropicProtocol.responseStream = [
            #"event: message_start\#ndata: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5"}}"#,
            #"event: content_block_start\#ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"event: content_block_delta\#ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"On it."}}"#,
            #"event: content_block_start\#ndata: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"open_app","input":{}}}"#,
            #"event: content_block_delta\#ndata: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"name\":\"Spotify\"}"}}"#,
            #"event: message_delta\#ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"event: message_stop\#ndata: {"type":"message_stop"}"#,
        ].joined(separator: "\n\n") + "\n\n"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAnthropicProtocol.self]
        let client = AnthropicClient(apiKey: "test-key", session: URLSession(configuration: config))
        let screen = ScreenCapture(promptBlock: "<screen>\n[1] Play\n</screen>", jpegBase64: "AAAA", imageSize: CGSize(width: 1280, height: 800))
        let turn = try await client.streamTurn(
            model: "claude-opus-5-5", effort: "low", system: "sys", tools: ClaudeAgentLoop.tools(for: .assistant),
            messages: [.object(["role": .string("user"), "content": .array(screen.contentBlocks(caption: "open spotify"))])]
        ) { _ in }

        #expect(turn.text == "On it.")
        #expect(turn.toolUses.first?.name == "open_app")
        #expect(turn.toolUses.first?.input?["name"] == .string("Spotify"))
        #expect(MockAnthropicProtocol.lastHeaders["x-api-key"] == "test-key")
        #expect(MockAnthropicProtocol.lastHeaders["anthropic-version"] == "2023-06-01")
        #expect(MockAnthropicProtocol.lastHeaders["anthropic-beta"] == "server-side-fallback-2026-07-01")
        guard case .object(let body)? = MockAnthropicProtocol.lastRequestBody else { Issue.record("no body"); return }
        #expect(body["model"] == .string("claude-opus-5-5"))
        #expect(body["fallbacks"] == .string("default"))
        #expect(body["stream"] == .bool(true))
        #expect(body["output_config"] == .object(["effort": .string("low")]))
        #expect(body["thinking"] == nil) // Opus 5.5 runs adaptive thinking by default
        guard case .array(let messages)? = body["messages"], case .object(let user)? = messages.first,
              case .array(let blocks)? = user["content"] else { Issue.record("no messages"); return }
        #expect(blocks.contains { if case .object(let b) = $0 { return b["type"] == .string("image") } else { return false } })
    }
}

@Suite struct LocalAgentTests {
    @Test func parsesDuckDuckGoResults() {
        let html = """
        <div class="result"><h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fjobs%3Fq%3Dintern&amp;rut=abc">Software <b>Intern</b> Jobs &amp; More</a></h2>
        <a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">Apply now for <b>internships</b> in Berlin&#39;s tech scene.</a></div>
        <div class="result"><a class="result__a" href="https://duckduckgo.com/y.js?ad_provider=x">Sponsored</a></div>
        <div class="result"><a rel="nofollow" class="result__a" href="https://second.example.org/">Second</a></div>
        """
        let results = WebTools.parseResults(html)
        #expect(results.count == 2) // the ad is skipped
        #expect(results[0] == WebTools.SearchResult(title: "Software Intern Jobs & More", url: "https://example.com/jobs?q=intern",
                                                    snippet: "Apply now for internships in Berlin's tech scene."))
        #expect(results[1].url == "https://second.example.org/")
        #expect(results[1].snippet.isEmpty)
    }

    @Test func turnsPagesIntoReadableText() {
        let html = """
        <html><head><title>Careers &ndash; Acme</title><style>.x{color:red}</style></head>
        <body><script>track()</script><h1>Open roles</h1><ul><li>ML Intern</li><li>iOS Intern</li></ul><p>Apply&nbsp;by Oct&#160;20.</p></body></html>
        """
        let text = WebTools.pageText(html)
        #expect(text.hasPrefix("# Careers – Acme"))
        #expect(text.contains("Open roles"))
        #expect(text.contains("• ML Intern"))
        #expect(text.contains("Apply by Oct 20."))
        #expect(!text.contains("track()") && !text.contains("color:red"))
    }

    @Test func parsesWebToolCalls() {
        #expect(AgentAction(call: ToolCall(name: "web_search", arguments: ["query": .string("berlin internships")])) == .webSearch("berlin internships"))
        #expect(AgentAction(call: ToolCall(name: "web_fetch", arguments: ["url": .string("https://example.com")])) == .webFetch("https://example.com"))
        #expect(!AgentAction.webSearch("x").isRisky)
        #expect(ToolCallParser.fallbackCalls(in: #"Searching. {"name": "web_search", "arguments": {"query": "x"}}"#).first?.function.name == "web_search")
    }

    @Test func claudeKeepsItsServerWebToolsAndLocalSpecialistsGetTheirs() {
        func names(_ tools: [JSONValue]) -> [String] {
            tools.compactMap { tool -> String? in
                guard case .object(let object) = tool else { return nil }
                if case .object(let function)? = object["function"] { return function["name"]?.stringValue }
                return object["name"]?.stringValue
            }
        }
        // Claude: one web_search (its server tool), never the local client version as well.
        let claude = names(ClaudeAgentLoop.tools(for: .assistant))
        #expect(claude.filter { $0 == "web_search" }.count == 1)
        // Local ZOOBIE can delegate and search; a local specialist gets its tools plus web search, nothing else.
        #expect(names(AgentLoop.tools).contains("delegate") && names(AgentLoop.tools).contains("web_search"))
        let executor = AgentExecutor(workingDirectory: "/tmp", timeout: 5)
        let jobs = AgentLoop(client: OllamaClient(baseURL: URL(string: "http://127.0.0.1:1")!), model: "m", options: .init(),
                             executor: executor, maxSteps: 1, role: .specialist(Specialist.get(.jobs), name: "Scrapeman", notebook: "", conversation: false))
        #expect(Set(names(jobs.tools)) == Specialist.get(.jobs).tools.union(["web_search", "web_fetch"]))
    }

    @Test func localPromptKnowsTheSpecialistsNames() {
        let prompt = Prompts.assistant(workingDirectory: "~", commandTimeout: 60, specialistNames: [.jobs: "Scrapeman"])
        #expect(prompt.contains("jobs is called Scrapeman"))
        #expect(prompt.contains("delegate"))
    }
}
