import Foundation

// MARK: - Tools

public enum AgentTools {
    public static let mediaCommands = ["play_pause", "next", "previous", "volume_up", "volume_down", "mute"]

    public static let names: Set<String> = [
        "open_app", "run_applescript", "media_control", "click", "type_text", "press_keys", "read_screen",
        "run_shell", "read_file", "write_file", "list_directory", "open_url", "delegate", "talk_to",
        "set_timer", "list_timers", "cancel_timer", "create_reminder", "list_events", "create_event", "update_notebook",
    ]

    /// Tools that drive the screen, mouse or keyboard. Background agents never get these, so they
    /// can't interfere with what the user is doing.
    public static let foregroundOnly: Set<String> = ["click", "type_text", "press_keys", "media_control", "read_screen", "delegate", "talk_to"]

    /// Only specialists keep a notebook.
    public static let specialistOnly: Set<String> = ["update_notebook"]

    /// Need the Claude brain (they hand work to Claude-powered specialists).
    public static let claudeOnly: Set<String> = ["delegate", "talk_to"]

    /// The definitions minus the named tools.
    public static func definitions(excluding excluded: Set<String>) -> [JSONValue] {
        definitions.filter { definition in
            guard case .object(let wrapper) = definition, case .object(let function)? = wrapper["function"],
                  let name = function["name"]?.stringValue else { return true }
            return !excluded.contains(name)
        }
    }

    public static let definitions: [JSONValue] = [
        tool("open_app", "Launch an app or bring it to the front.", ["name": "App name, e.g. Spotify, Safari, Visual Studio Code."], required: ["name"]),
        tool("run_applescript", "Run AppleScript to control a scriptable app or the system, e.g. tell application \"Spotify\" to play, tell application \"Music\" to next track, set volume output volume 40, tell application \"Safari\" to make new document.",
             ["script": "The AppleScript source."], required: ["script"]),
        tool("media_control", "Press a media key; works with whatever app is playing audio. play_pause toggles.",
             ["command": "One of: \(mediaCommands.joined(separator: ", "))."], required: ["command"]),
        tool("click", "Click something visible on screen.",
             ["target": "The [id] number of the element from the latest <screen>, its exact visible text, or x,y pixel coordinates in the latest screenshot."], required: ["target"]),
        tool("type_text", "Type text into whatever currently has keyboard focus.", ["text": "The text to type."], required: ["text"]),
        tool("press_keys", "Press a key or shortcut in the frontmost app, e.g. cmd+t, return, cmd+shift+n, escape, down.",
             ["keys": "Keys joined with +."], required: ["keys"]),
        tool("read_screen", "Read the screen again (OCR) after something changed. Returns a fresh <screen> block.", [:], required: []),
        tool("run_shell", "Run a zsh command and return its combined stdout/stderr and exit code.",
             ["command": "The shell command to run.", "cwd": "Optional working directory (absolute path)."], required: ["command"]),
        tool("read_file", "Read a UTF-8 text file.", ["path": "Absolute path of the file."], required: ["path"]),
        tool("write_file", "Create or overwrite a UTF-8 text file with the full given content.",
             ["path": "Absolute path of the file.", "content": "The complete new file content."], required: ["path", "content"]),
        tool("list_directory", "List the entries of a directory.", ["path": "Absolute path of the directory."], required: ["path"]),
        tool("open_url", "Open a URL or file in its default app, e.g. a web page in the browser.",
             ["url": "The URL or absolute file path to open."], required: ["url"]),
        tool("delegate", "Hand a longer job to one of the four background specialists so the user can keep working; it reports back when done. Specialists: jobs (job/internship search, application tracking, CVs, cover letters), mentor (software development, Python/FastAPI, AI/ML, academic assignments), schedule (calendar, reminders, timers, daily admin), german (German grammar, vocabulary, practice material).",
             ["agent": "One of: jobs, mentor, schedule, german.", "title": "A short title, 2 to 5 words.", "task": "The full task with everything the specialist needs to know."], required: ["agent", "title", "task"]),
        tool("talk_to", "Switch the live conversation to a specialist (for example German practice with the tutor). The user talks to them directly until they say they're done.",
             ["agent": "One of: jobs, mentor, schedule, german."], required: ["agent"]),
        tool("set_timer", "Start a countdown timer; ZOOBIE announces it out loud when it ends.",
             ["minutes": "Length in minutes (decimals allowed, e.g. 0.5).", "label": "What it's for, e.g. Pasta or Focus session."], required: ["minutes"]),
        tool("list_timers", "List running timers and how much time is left.", [:], required: []),
        tool("cancel_timer", "Cancel a running timer.", ["label": "The timer's label, or 'all'."], required: ["label"]),
        tool("create_reminder", "Add a reminder to Apple Reminders, optionally with a due date and time.",
             ["title": "The reminder.", "due": "Local date and time as YYYY-MM-DDTHH:MM (optional).", "notes": "Extra details (optional)."], required: ["title"]),
        tool("list_events", "List Calendar events in a date range.",
             ["from": "Start as YYYY-MM-DD or YYYY-MM-DDTHH:MM (default: today).", "to": "End, exclusive (default: one day after start)."], required: []),
        tool("create_event", "Create a Calendar event.",
             ["title": "Event title.", "start": "Local start as YYYY-MM-DDTHH:MM.", "end": "Local end as YYYY-MM-DDTHH:MM (default: one hour later).", "location": "Optional location."], required: ["title", "start"]),
        tool("update_notebook", "Rewrite your notebook: the long-term memory you keep between conversations (trackers, the learner's level, preferences, ongoing work). Send the complete new notebook.",
             ["content": "The full Markdown notebook."], required: ["content"]),
    ]

    private static func tool(_ name: String, _ description: String, _ params: [String: String], required: [String]) -> JSONValue {
        let properties = params.mapValues { JSONValue.object(["type": .string("string"), "description": .string($0)]) }
        return .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object(properties),
                    "required": .array(required.map { .string($0) }),
                ]),
            ]),
        ])
    }
}

// MARK: - Actions

public enum ApprovalPolicy: String, Codable, Sendable {
    /// Ask only for actions that change or delete things, send, install, or quit.
    case risky
    case always
    case never
}

public enum AgentAction: Sendable, Equatable {
    case openApp(String)
    case appleScript(String)
    case media(String)
    case click(target: String)
    case typeText(String)
    case pressKeys(String)
    case readScreen
    case delegate(agent: Specialist.ID, title: String, task: String)
    case talkTo(Specialist.ID)
    case setTimer(seconds: Int, label: String)
    case listTimers
    case cancelTimer(String)
    case createReminder(title: String, due: Date?, notes: String?)
    case listEvents(from: Date, to: Date)
    case createEvent(title: String, start: Date, end: Date, location: String?)
    case updateNotebook(String)
    case shell(command: String, cwd: String?)
    case readFile(path: String)
    case writeFile(path: String, content: String)
    case listDirectory(path: String)
    case openURL(String)
    case invalid(name: String, reason: String)

    private static let placeholderPattern = try! NSRegularExpression(
        pattern: #"(/path/to/|path/to/your|/your[-_/]|your[-_]project|<your|/Users/(username|you|user)/|YOUR_[A-Z])"#,
        options: [.caseInsensitive]
    )

    public init(call: ToolCall) {
        self.init(parsing: call)
        // Small models write "/path/to/your/project" when they don't know a path; never run those.
        if case .invalid = self { return }
        if Self.matches(Self.placeholderPattern, detail) {
            self = .invalid(name: call.function.name, reason: "it uses a placeholder path. Find the real path first (window title, list_directory, mdfind) or ask the user")
        }
    }

    private init(parsing call: ToolCall) {
        let args = call.function.arguments
        func arg(_ key: String) -> String? {
            guard let value = args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let name = call.function.name
        func missing(_ key: String) -> AgentAction { .invalid(name: name, reason: "missing '\(key)'") }
        switch name {
        case "open_app":
            self = arg("name").map(AgentAction.openApp) ?? missing("name")
        case "run_applescript":
            self = arg("script").map(AgentAction.appleScript) ?? missing("script")
        case "media_control":
            guard let command = arg("command")?.lowercased() else { self = missing("command"); return }
            self = AgentTools.mediaCommands.contains(command)
                ? .media(command)
                : .invalid(name: name, reason: "command must be one of \(AgentTools.mediaCommands.joined(separator: ", "))")
        case "click":
            self = arg("target").map { .click(target: $0) } ?? missing("target")
        case "type_text":
            // Typed text may legitimately be only whitespace, so read it raw.
            guard let text = args["text"]?.stringValue, !text.isEmpty else { self = missing("text"); return }
            self = .typeText(text)
        case "press_keys":
            self = arg("keys").map(AgentAction.pressKeys) ?? missing("keys")
        case "read_screen":
            self = .readScreen
        case "delegate":
            guard let task = arg("task") else { self = missing("task"); return }
            guard let agent = arg("agent").flatMap(Specialist.resolve) else {
                self = .invalid(name: name, reason: "agent must be one of jobs, mentor, schedule, german")
                return
            }
            self = .delegate(agent: agent.id, title: arg("title") ?? String(task.prefix(40)), task: task)
        case "talk_to":
            guard let agent = arg("agent").flatMap(Specialist.resolve) else {
                self = .invalid(name: name, reason: "agent must be one of jobs, mentor, schedule, german")
                return
            }
            self = .talkTo(agent.id)
        case "set_timer":
            guard let minutes = arg("minutes").flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }), minutes > 0 else {
                self = .invalid(name: name, reason: "minutes must be a positive number")
                return
            }
            self = .setTimer(seconds: max(1, Int((minutes * 60).rounded())), label: arg("label") ?? "Timer")
        case "list_timers":
            self = .listTimers
        case "cancel_timer":
            self = .cancelTimer(arg("label") ?? "all")
        case "create_reminder":
            guard let title = arg("title") else { self = missing("title"); return }
            let due = arg("due")
            if let due, LocalDate.parse(due) == nil {
                self = .invalid(name: name, reason: "due must look like 2026-10-02T18:00")
                return
            }
            self = .createReminder(title: title, due: due.flatMap(LocalDate.parse), notes: arg("notes"))
        case "list_events":
            let from = arg("from").flatMap(LocalDate.parse) ?? Calendar.current.startOfDay(for: Date())
            let to = arg("to").flatMap(LocalDate.parse) ?? from.addingTimeInterval(86_400)
            self = .listEvents(from: from, to: to)
        case "create_event":
            guard let title = arg("title") else { self = missing("title"); return }
            guard let start = arg("start").flatMap(LocalDate.parse) else {
                self = .invalid(name: name, reason: "start must look like 2026-10-02T18:00")
                return
            }
            let end = arg("end").flatMap(LocalDate.parse) ?? start.addingTimeInterval(3600)
            self = .createEvent(title: title, start: start, end: max(end, start.addingTimeInterval(60)), location: arg("location"))
        case "update_notebook":
            guard let content = args["content"]?.stringValue else { self = missing("content"); return }
            self = .updateNotebook(content)
        case "run_shell":
            guard let command = arg("command") else { self = missing("command"); return }
            self = .shell(command: command, cwd: arg("cwd"))
        case "read_file":
            self = arg("path").map { .readFile(path: $0) } ?? missing("path")
        case "write_file":
            guard let path = arg("path") else { self = missing("path"); return }
            self = .writeFile(path: path, content: args["content"]?.stringValue ?? "")
        case "list_directory":
            self = .listDirectory(path: arg("path") ?? ".")
        case "open_url":
            self = arg("url").map(AgentAction.openURL) ?? missing("url")
        default:
            self = .invalid(name: name, reason: "unknown tool; available: \(AgentTools.names.sorted().joined(separator: ", "))")
        }
    }

    public var title: String {
        switch self {
        case .openApp(let name): return "Open \(name)"
        case .appleScript: return "Run AppleScript"
        case .media(let command): return command.replacingOccurrences(of: "_", with: " ").capitalized
        case .click: return "Click"
        case .typeText: return "Type text"
        case .pressKeys(let keys): return "Press \(keys)"
        case .readScreen: return "Read the screen"
        case .delegate(let agent, let title, _): return "Delegate to \(Specialist.get(agent).defaultName): \(title)"
        case .talkTo(let agent): return "Talk to \(Specialist.get(agent).defaultName)"
        case .setTimer(let seconds, let label): return "Timer \(Self.duration(seconds)): \(label)"
        case .listTimers: return "List timers"
        case .cancelTimer(let label): return "Cancel timer: \(label)"
        case .createReminder(let title, _, _): return "Add reminder: \(title)"
        case .listEvents: return "Check calendar"
        case .createEvent(let title, _, _, _): return "Add event: \(title)"
        case .updateNotebook: return "Update notebook"
        case .shell: return "Run command"
        case .readFile: return "Read file"
        case .writeFile: return "Write file"
        case .listDirectory: return "List directory"
        case .openURL: return "Open"
        case .invalid(let name, _): return "Invalid call: \(name)"
        }
    }

    public var detail: String {
        switch self {
        case .openApp(let name): return name
        case .appleScript(let script): return script
        case .media(let command): return command
        case .click(let target): return target
        case .typeText(let text): return text
        case .pressKeys(let keys): return keys
        case .readScreen: return ""
        case .delegate(_, _, let task): return task
        case .talkTo(let agent): return Specialist.get(agent).role
        case .setTimer(let seconds, let label): return "\(label) — \(Self.duration(seconds))"
        case .listTimers: return ""
        case .cancelTimer(let label): return label
        case .createReminder(let title, let due, let notes):
            return [title, due.map { "due " + LocalDate.describe($0) }, notes].compactMap { $0 }.joined(separator: " · ")
        case .listEvents(let from, let to): return "\(LocalDate.describe(from)) → \(LocalDate.describe(to))"
        case .createEvent(let title, let start, let end, let location):
            return [title, "\(LocalDate.describe(start)) – \(LocalDate.describe(end))", location].compactMap { $0 }.joined(separator: " · ")
        case .updateNotebook(let content): return "\(content.count) characters"
        case .shell(let command, let cwd): return cwd.map { "cd \($0) && \(command)" } ?? command
        case .readFile(let path), .listDirectory(let path): return path
        case .writeFile(let path, let content): return "\(path)  (\(content.count) chars)\n\n\(content.prefix(1200))"
        case .openURL(let url): return url
        case .invalid(_, let reason): return reason
        }
    }

    public func needsApproval(under policy: ApprovalPolicy) -> Bool {
        switch policy {
        case .always: if case .invalid = self { return false } else { return true }
        case .never: return false
        case .risky: return isRisky
        }
    }

    /// Changes, deletes, sends, installs or quits something — worth a confirmation.
    public var isRisky: Bool {
        switch self {
        case .shell(let command, _): return !Self.isReadOnlyShell(command)
        case .writeFile: return true
        case .appleScript(let script): return Self.matches(Self.riskyScriptPattern, script)
        case .click(let target): return Self.matches(Self.riskyLabelPattern, target)
        case .pressKeys(let keys): return Self.riskyShortcuts.contains(Self.normalizedKeys(keys))
        case .openApp, .media, .typeText, .readScreen, .readFile, .listDirectory, .openURL, .invalid,
             .delegate, .talkTo, .setTimer, .listTimers, .cancelTimer, .createReminder, .listEvents, .createEvent, .updateNotebook:
            return false
        }
    }

    /// Shown as a CAUTION badge: the action can destroy data or is hard to undo.
    public var isDestructive: Bool {
        switch self {
        case .shell(let command, _): return Self.matches(Self.destructivePattern, command)
        case .writeFile: return true
        case .appleScript(let script): return Self.matches(Self.destructiveScriptPattern, script)
        default: return false
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60, rest = seconds % 60
        if minutes < 60 { return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: Risk rules

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let destructivePattern = try! NSRegularExpression(pattern: [
        #"(^|[;&|(\s])(sudo|rm|rmdir|mv|dd|mkfs\S*|shred|kill|killall|pkill|chmod|chown|diskutil|launchctl|truncate)(\s|$)"#,
        #"git\s+(push|reset|clean|rebase|checkout\s+--|restore|branch\s+-D|stash\s+drop)"#,
        #"(brew|npm|pip3?|cargo)\s+(uninstall|remove|publish|unpublish)"#,
        #"--force\b|\s-[a-zA-Z]*f[a-zA-Z]*\s+/"#,
        #"(^|[^>&0-9])>\s*[^&\s]"#,
        #"curl[^|]*\|\s*(ba|z)?sh"#,
    ].joined(separator: "|"))

    private static let riskyScriptPattern = try! NSRegularExpression(
        pattern: #"\b(delete|remove|move|duplicate|empty|erase|trash|quit|close|shut\s*down|restart|log\s*out|send|save|make\s+new\s+(outgoing\s+)?message|reply|forward|purchase|buy|do\s+shell\s+script)\b"#,
        options: [.caseInsensitive]
    )
    private static let destructiveScriptPattern = try! NSRegularExpression(
        pattern: #"\b(delete|erase|empty\s+(the\s+)?trash|remove|do\s+shell\s+script)\b"#, options: [.caseInsensitive]
    )
    private static let riskyLabelPattern = try! NSRegularExpression(
        pattern: #"\b(delete|remove|send|submit|pay|buy|purchase|place\s+order|confirm|erase|trash|uninstall|sign\s*out|log\s*out|discard|reset|format|unsubscribe)\b"#,
        options: [.caseInsensitive]
    )
    private static let riskyShortcuts: Set<String> = ["cmd+q", "cmd+w", "cmd+delete", "cmd+backspace", "cmd+option+escape", "cmd+shift+delete", "ctrl+cmd+q", "cmd+shift+q"]

    public static func normalizedKeys(_ keys: String) -> String {
        let aliases = ["command": "cmd", "⌘": "cmd", "control": "ctrl", "⌃": "ctrl", "alt": "option", "opt": "option", "⌥": "option",
                       "esc": "escape", "backspace": "delete", "enter": "return"]
        let parts = keys.lowercased().split(separator: "+").map { part -> String in
            let key = part.trimmingCharacters(in: .whitespaces)
            return aliases[key] ?? key
        }
        let order = ["ctrl", "option", "shift", "cmd"]
        let modifiers = order.filter(parts.contains)
        return (modifiers + parts.filter { !order.contains($0) }).joined(separator: "+")
    }

    private static let readOnlyCommands: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "echo", "which", "whoami", "date", "uname", "df", "du", "ps", "grep", "rg",
        "file", "stat", "sw_vers", "system_profiler", "mdfind", "mdls", "pmset", "uptime", "printenv", "tree", "sort", "uniq",
        "cut", "jq", "lsof", "open", "id", "hostname", "cal", "basename", "dirname", "realpath", "shasum", "md5", "diff",
    ]
    private static let readOnlyGit: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "ls-files", "blame", "describe", "tag"]

    /// True for commands that only look at things: read-only programs, no redirection or substitution.
    public static func isReadOnlyShell(_ command: String) -> Bool {
        if matches(destructivePattern, command) || command.contains("$(") || command.contains("`") { return false }
        let segments = command.components(separatedBy: CharacterSet(charactersIn: ";&|")).map { $0.trimmingCharacters(in: .whitespaces) }
        return segments.filter { !$0.isEmpty }.allSatisfy { segment in
            let words = segment.split(separator: " ").map(String.init)
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return true }
            let second = words.dropFirst().first ?? ""
            switch program {
            case "git": return readOnlyGit.contains(second) && !segment.contains(" -D") && !segment.contains(" -d ")
            case "defaults": return second == "read"
            case "find": return !["-delete", "-exec", "-ok"].contains { segment.contains($0) }
            case "networksetup": return second.hasPrefix("-get") || second.hasPrefix("-list")
            case "top": return segment.contains("-l")
            default: return readOnlyCommands.contains(program)
            }
        }
    }
}

// MARK: - Fallback parsing

/// Small local models often write the call into the reply text instead of `tool_calls` —
/// qwen2.5-coder emits bare JSON after a line of prose; others use `<tool_call>` tags or a ```json
/// block. This recovers those calls.
public enum ToolCallParser {
    private static let tagPattern = try! NSRegularExpression(pattern: #"<tool_call>([\s\S]*?)(?:</tool_call>|$)"#)
    private static let fencePattern = try! NSRegularExpression(pattern: #"```(?:json)?\s*\n([\s\S]*?)```"#)

    public static func fallbackCalls(in content: String) -> [ToolCall] {
        let groups = [
            captures(tagPattern, in: content),
            captures(fencePattern, in: content),
            jsonObjects(in: content).complete.map { String(content[$0]) },
        ]
        for group in groups {
            let calls = group.flatMap { parseCalls($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if !calls.isEmpty { return calls }
        }
        return []
    }

    /// The reply text with any embedded call markup removed, for display. Also hides a call that is
    /// still streaming in, so the user never sees half-written JSON.
    public static func strippingCalls(_ content: String) -> String {
        var text = tagPattern.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
        for match in fencePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let range = Range(match.range, in: text)!
            let inner = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            if !parseCalls(inner.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty { text.removeSubrange(range) }
        }
        let objects = jsonObjects(in: text)
        if let open = objects.openStart, !isInsideCodeFence(text, at: open) {
            text.removeSubrange(open...) // most likely a tool call that's still streaming in
        }
        for range in objects.complete.reversed() where range.upperBound <= text.endIndex {
            if !parseCalls(String(text[range])).isEmpty { text.removeSubrange(range) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isInsideCodeFence(_ text: String, at index: String.Index) -> Bool {
        text[..<index].split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count % 2 == 1
    }

    /// Top-level balanced `{…}` spans, ignoring braces inside JSON strings. `openStart` marks an
    /// object that hasn't closed yet (e.g. mid-stream).
    static func jsonObjects(in text: String) -> (complete: [Range<String.Index>], openStart: String.Index?) {
        var complete: [Range<String.Index>] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" && depth > 0 {
                inString = true
            } else if char == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if char == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    complete.append(s..<text.index(after: index))
                    start = nil
                }
            }
            index = text.index(after: index)
        }
        return (complete, depth > 0 ? start : nil)
    }

    private static func parseCalls(_ text: String) -> [ToolCall] {
        guard let value = JSONValue.parse(text) else { return [] }
        let items: [JSONValue]
        if case .array(let array) = value { items = array } else { items = [value] }
        return items.compactMap { item in
            guard case .object(var object) = item else { return nil }
            if case .object(let function)? = object["function"] { object = function }
            guard let name = object["name"]?.stringValue, AgentTools.names.contains(name) else { return nil }
            switch object["arguments"] ?? object["parameters"] {
            case .object(let args)?: return ToolCall(name: name, arguments: args)
            case .string(let s)?:
                if case .object(let args)? = JSONValue.parse(s) { return ToolCall(name: name, arguments: args) }
                return nil
            default: return ToolCall(name: name, arguments: [:])
            }
        }
    }

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Execution

public struct AgentExecutor: Sendable {
    public typealias UIHandler = @Sendable (AgentAction) async -> String

    public var workingDirectory: String
    public var timeout: TimeInterval
    public var outputLimit = 6000
    /// Performs screen/keyboard/media/timer/agent actions, which need the app.
    public var ui: UIHandler?
    /// Where update_notebook writes (set for specialists).
    public var notebookURL: URL?

    public init(workingDirectory: String, timeout: TimeInterval, ui: UIHandler? = nil, notebookURL: URL? = nil) {
        self.workingDirectory = (workingDirectory as NSString).expandingTildeInPath
        self.timeout = timeout
        self.ui = ui
        self.notebookURL = notebookURL
    }

    private func runAppleScript(_ script: String) async -> String {
        let result = await Shell.run("/usr/bin/osascript -e \(Shell.quote(script))", cwd: workingDirectory, timeout: timeout)
        if result.timedOut { return "Error: timed out after \(Int(timeout))s" }
        if result.exitCode != 0 { return Self.explainAppleScriptError(result.output) }
        return result.output.isEmpty ? "Done." : truncate(result.output)
    }

    public func execute(_ action: AgentAction) async -> String {
        switch action {
        case .openApp(let name):
            let result = await Shell.run("/usr/bin/open -a \(Shell.quote(name))", cwd: workingDirectory, timeout: 20)
            return result.exitCode == 0 ? "\(name) is open and in front." : "Couldn't open \(name): \(result.output)"
        case .appleScript(let script):
            let result = await Shell.run("/usr/bin/osascript -e \(Shell.quote(script))", cwd: workingDirectory, timeout: timeout)
            if result.timedOut { return "AppleScript timed out after \(Int(timeout))s" }
            if result.exitCode != 0 { return Self.explainAppleScriptError(result.output) }
            return result.output.isEmpty ? "Done." : truncate(result.output)
        case .createReminder(let title, let due, let notes):
            return await runAppleScript(AppleAppScripts.createReminder(title: title, due: due, notes: notes))
        case .listEvents(let from, let to):
            return await runAppleScript(AppleAppScripts.listEvents(from: from, to: to))
        case .createEvent(let title, let start, let end, let location):
            return await runAppleScript(AppleAppScripts.createEvent(title: title, start: start, end: end, location: location))
        case .updateNotebook(let content):
            guard let notebookURL else { return "Error: only specialists keep a notebook." }
            do {
                try content.write(to: notebookURL, atomically: true, encoding: .utf8)
                return "Notebook saved."
            } catch {
                return "Error saving notebook: \(error.localizedDescription)"
            }
        case .media, .click, .typeText, .pressKeys, .readScreen, .delegate, .talkTo, .setTimer, .listTimers, .cancelTimer:
            guard let ui else { return "Error: \(action.title) isn't available here." }
            return await ui(action)
        case .shell(let command, let cwd):
            let result = await Shell.run(command, cwd: cwd.map(resolve) ?? workingDirectory, timeout: timeout)
            var text = truncate(result.output.isEmpty ? "(no output)" : result.output)
            text += result.timedOut ? "\n[timed out after \(Int(timeout))s]" : "\n[exit code \(result.exitCode)]"
            return text
        case .readFile(let path):
            do {
                return truncate(try String(contentsOfFile: resolve(path), encoding: .utf8))
            } catch {
                return "Error reading \(path): \(error.localizedDescription)"
            }
        case .writeFile(let path, let content):
            let url = URL(fileURLWithPath: resolve(path))
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return "Wrote \(content.utf8.count) bytes to \(url.path)"
            } catch {
                return "Error writing \(path): \(error.localizedDescription)"
            }
        case .listDirectory(let path):
            let dir = resolve(path)
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
                let lines = entries.prefix(300).map { name -> String in
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDir)
                    return isDir.boolValue ? name + "/" : name
                }
                let more = entries.count > 300 ? "\n… \(entries.count - 300) more" : ""
                return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n") + more
            } catch {
                return "Error listing \(path): \(error.localizedDescription)"
            }
        case .openURL(let target):
            let arg = target.contains("://") ? target : resolve(target)
            let result = await Shell.run("/usr/bin/open \(Shell.quote(arg))", cwd: workingDirectory, timeout: 15)
            return result.exitCode == 0 ? "Opened \(target)" : "Failed to open \(target): \(result.output)"
        case .invalid(let name, let reason):
            return "Error: invalid call to \(name): \(reason)"
        }
    }

    /// Turns osascript failures into something the model can act on and say out loud.
    static func explainAppleScriptError(_ output: String) -> String {
        if output.contains("-1743") || output.localizedCaseInsensitiveContains("not authorized to send apple events") {
            return "Error: macOS blocked Companion from controlling that app. Tell the user to allow Companion under System Settings > Privacy & Security > Automation, then try again."
        }
        if output.contains("-1728") || output.contains("-1708") {
            return "AppleScript error: that app doesn't understand this command (\(output)). Try another approach, e.g. media_control or press_keys."
        }
        if output.contains("-600") {
            return "AppleScript error: the app isn't running. Open it with open_app first."
        }
        return "AppleScript error: \(output)"
    }

    func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return ((workingDirectory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    private func truncate(_ text: String) -> String {
        guard text.count > outputLimit else { return text }
        let head = text.prefix(outputLimit * 2 / 3)
        let tail = text.suffix(outputLimit / 3)
        return "\(head)\n… [\(text.count - head.count - tail.count) characters omitted] …\n\(tail)"
    }
}

public enum Shell {
    public struct Result: Sendable {
        public var exitCode: Int32
        public var output: String
        public var timedOut: Bool
    }

    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `command` with zsh, stdout and stderr merged, killing it after `timeout` seconds.
    public static func run(_ command: String, cwd: String, timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                // Apps launched from Finder get a minimal PATH; add the usual developer locations.
                env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                env["GIT_PAGER"] = "cat"
                env["PAGER"] = "cat"
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(exitCode: -1, output: "Failed to launch: \(error.localizedDescription)", timedOut: false))
                    return
                }
                let timedOut = LockedFlag()
                let killer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    timedOut: timedOut.value
                ))
            }
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

// MARK: - Loop

public enum AgentDecision: Sendable {
    case run, skip, stop
}

public enum AgentEvent: Sendable {
    /// The model starts a new turn (its first reply, or a follow-up after a tool result).
    case turnStarted
    /// The model's visible text for the current turn so far (replaces the previous value).
    case thinking(String)
    /// An action waiting for the user's approval.
    case proposed(AgentAction)
    /// An action that runs without asking (harmless under the approval policy).
    case running(AgentAction)
    case output(AgentAction, String)
    case skipped(AgentAction)
    /// Server-side research progress (web searches and fetches Anthropic ran).
    case research(String)
    case finished(String)
    case stopped
}

/// One brain for everything: it answers questions directly and acts through tools when asked to do
/// something. Harmless actions run immediately; risky ones wait for the user's decision.
public struct AgentLoop: Sendable {
    public var client: OllamaClient
    public var model: String
    public var options: OllamaClient.Options
    public var executor: AgentExecutor
    public var maxSteps: Int
    public var policy: ApprovalPolicy

    public init(client: OllamaClient, model: String, options: OllamaClient.Options, executor: AgentExecutor, maxSteps: Int, policy: ApprovalPolicy = .risky) {
        self.client = client
        self.model = model
        self.options = options
        self.executor = executor
        self.maxSteps = maxSteps
        self.policy = policy
    }

    /// Returns the final reply text ("" if stopped).
    @discardableResult
    public func run(
        request: String,
        screen: String?,
        history: [ChatMessage] = [],
        confirm: @Sendable (AgentAction) async -> AgentDecision,
        emit: @Sendable (AgentEvent) async -> Void
    ) async throws -> String {
        let system = Prompts.assistant(workingDirectory: executor.workingDirectory, commandTimeout: Int(executor.timeout))
        let userContent = screen.map { "\($0)\n\n\(request)" } ?? request
        var messages = [ChatMessage(role: .system, content: system)] + history + [ChatMessage(role: .user, content: userContent)]
        var nudgesLeft = 2

        for _ in 0..<maxSteps {
            await emit(.turnStarted)
            var content = ""
            var calls: [ToolCall] = []
            for try await chunk in client.chat(model: model, messages: messages, tools: AgentTools.definitions(excluding: AgentTools.claudeOnly.union(AgentTools.specialistOnly)), options: options) {
                guard let message = chunk.message else { continue }
                if let toolCalls = message.toolCalls { calls += toolCalls }
                if !message.content.isEmpty {
                    content += message.content
                    await emit(.thinking(ToolCallParser.strippingCalls(content)))
                }
            }
            try Task.checkCancellation()
            if calls.isEmpty {
                calls = ToolCallParser.fallbackCalls(in: content)
                if !calls.isEmpty { content = ToolCallParser.strippingCalls(content) }
            }
            messages.append(ChatMessage(role: .assistant, content: content, toolCalls: calls.isEmpty ? nil : calls))
            if calls.isEmpty {
                // Small models often narrate the next step ("Opening Spotify…") without calling a tool.
                if nudgesLeft > 0, Self.announcesPendingStep(content) {
                    nudgesLeft -= 1
                    messages.append(ChatMessage(role: .user, content: Self.nudge))
                    continue
                }
                await emit(.finished(content))
                return content
            }
            for call in calls {
                let action = AgentAction(call: call)
                let result: String
                if case .invalid = action {
                    result = await executor.execute(action)
                    await emit(.output(action, result))
                } else if action.needsApproval(under: policy) {
                    await emit(.proposed(action))
                    switch await confirm(action) {
                    case .stop:
                        await emit(.stopped)
                        return ""
                    case .skip:
                        result = "The user declined this step. Do not retry it; choose another approach or finish."
                        await emit(.skipped(action))
                    case .run:
                        try Task.checkCancellation()
                        result = await executor.execute(action)
                        await emit(.output(action, result))
                    }
                } else {
                    await emit(.running(action))
                    result = await executor.execute(action)
                    await emit(.output(action, result))
                }
                try Task.checkCancellation()
                messages.append(ChatMessage(role: .tool, content: result, toolName: call.function.name))
            }
        }
        let limit = "I stopped after \(maxSteps) steps without finishing. Try a narrower request."
        await emit(.finished(limit))
        return limit
    }

    static let nudge = """
        You described a next step but did not call a tool, so nothing happened. If the task is not finished, \
        call the tool now. If it is finished, reply with the final summary only.
        """

    private static let pendingStepPattern = try! NSRegularExpression(
        pattern: #"(\b(I'll|I will|I'm going to|I am going to|let me(?! know)|let's|next,? I|now,? I)\b)|(^\s*(Now,?\s+|Next,?\s+)?(Writing|Creating|Running|Checking|Listing|Reading|Opening|Installing|Updating|Deleting|Moving|Copying|Searching|Fetching|Executing|Resuming|Playing|Pausing|Launching|Starting|Stopping|Clicking|Typing|Pressing|Skipping|Turning|Setting|Closing)\b)"#,
        options: [.caseInsensitive]
    )

    /// True when the reply's last sentence promises an action instead of reporting a result.
    static func announcesPendingStep(_ text: String) -> Bool {
        // Split on terminators followed by whitespace so "summary.txt" stays one word.
        let sentences = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?]+(\s+|$)"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = sentences.last else { return false }
        return pendingStepPattern.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)) != nil
    }
}
