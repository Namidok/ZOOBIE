import Foundation

/// Everyday commands recognised without the model: open an app or a website, control music and
/// volume, set a timer, tell the time. They act in a fraction of a second, even while the model is
/// slow or busy. Anything else, and any command whose action fails, goes to the model.
public enum QuickCommand: Equatable, Sendable {
    case openApp(String)
    case openWebsite(url: String, browser: String?)
    case play, pause, next, previous
    case setVolume(Int)
    case changeVolume(up: Bool)
    case mute(Bool)
    case timer(seconds: Int, label: String)
    case time, date

    // MARK: Matching

    public static func match(_ request: String) -> QuickCommand? {
        let text = clean(request)
        guard !text.isEmpty else { return nil }
        if let url = capture(website, text, group: "url") {
            let browser = capture(website, text, group: "browser").map { browsers[$0.lowercased()] ?? $0 }
            return .openWebsite(url: url.contains("://") ? url : "https://" + url, browser: browser)
        }
        if let name = capture(openApp, text), let app = appName(name) { return .openApp(app) }
        if matches(pausePattern, text) { return .pause }
        if matches(playPattern, text) { return .play }
        if matches(nextPattern, text) { return .next }
        if matches(previousPattern, text) { return .previous }
        if let level = capture(setVolume, text).flatMap(Int.init) { return .setVolume(min(100, level)) }
        if matches(volumeUp, text) { return .changeVolume(up: true) }
        if matches(volumeDown, text) { return .changeVolume(up: false) }
        if matches(mute, text) { return .mute(true) }
        if matches(unmute, text) { return .mute(false) }
        for pattern in [timerFor, timerAfter] {
            if let amount = capture(pattern, text), let unit = capture(pattern, text, group: "unit"),
               let seconds = seconds(amount, unit: unit) {
                return .timer(seconds: seconds, label: capture(pattern, text, group: "label") ?? "Timer")
            }
        }
        if matches(timePattern, text) { return .time }
        if matches(datePattern, text) { return .date }
        return nil
    }

    /// Drops what speech and politeness add: capitals don't matter (patterns ignore case), but
    /// "hey ZOOBIE, can you …, please." and the final full stop do.
    static func clean(_ request: String) -> String {
        var text = request.replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.!?,;"))
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let leading = #"^(?:(?:hey|hi|okay|ok|so|um|uh|zoobie|please|just|can you|could you|would you|will you)[ ,]+)+"#
        let trailing = #"(?:[ ,]+(?:please|for me|now|right now|thanks|thank you))+$"#
        text = text.replacingOccurrences(of: leading, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: trailing, with: "", options: [.regularExpression, .caseInsensitive])
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;"))
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "^(?:" + pattern + ")$", options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The named group (or the first group) of a full match.
    private static func capture(_ regex: NSRegularExpression, _ text: String, group: String? = nil) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let range = group.map { match.range(withName: $0) } ?? match.range(at: 1)
        return Range(range, in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
    }

    private static let fileExtensions = [
        "txt", "md", "pdf", "swift", "py", "js", "ts", "json", "png", "jpg", "jpeg", "gif", "heic", "doc", "docx", "xls", "xlsx",
        "csv", "zip", "html", "htm", "sh", "rtf", "pages", "key", "numbers", "mov", "mp4", "mp3", "app", "dmg", "log", "yaml", "yml",
    ]
    /// A domain ("github.com", "https://example.org/docs"), but not a file name ("notes.txt").
    private static let website = regex(
        #"(?:open|go to|visit|take me to|pull up)\s+(?<url>(?:https?://)?(?:[a-z0-9-]+\.)+(?!(?:"#
            + fileExtensions.joined(separator: "|")
            + #")(?:/|\s|$))[a-z]{2,}(?:/[^\s"]*)?)(?:\s+(?:in|on|with|using)\s+(?<browser>safari|google chrome|chrome|firefox|arc|brave|edge))?"#
    )
    private static let browsers = ["safari": "Safari", "chrome": "Google Chrome", "google chrome": "Google Chrome",
                                   "firefox": "Firefox", "arc": "Arc", "brave": "Brave Browser", "edge": "Microsoft Edge"]

    private static let openApp = regex(#"(?:open|open up|launch|switch to|bring up)\s+(?:the\s+)?(?:app\s+)?(.+?)(?:\s+app)?"#)
    /// Words that mean the request is about something inside an app, not the app itself.
    private static let notAppWords: Set<String> = [
        "a", "an", "my", "your", "new", "tab", "tabs", "window", "windows", "file", "files", "folder", "folders", "document",
        "documents", "the", "this", "that", "it", "in", "for", "with", "and", "to", "on", "from", "me", "some", "page", "link",
        "website", "site", "url", "last", "recent", "all", "of", "up", "i", "was", "is",
    ]
    private static let appAliases = ["vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
                                     "chrome": "Google Chrome", "whatsapp": "WhatsApp", "facetime": "FaceTime", "iterm": "iTerm",
                                     "xcode": "Xcode", "imessage": "Messages", "settings": "System Settings", "app store": "App Store"]

    private static func appName(_ raw: String) -> String? {
        let name = raw.lowercased()
        let words = name.split(separator: " ").map(String.init)
        guard (1...3).contains(words.count), !words.contains(where: notAppWords.contains) else { return nil }
        return appAliases[name] ?? words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let media = #"(?:music|song|track|playback|spotify|audio|podcast|video|it)"#
    private static let pausePattern = regex(#"pause(?:\s+(?:the|my))?(?:\s+"# + media + #")?|stop(?:\s+(?:the|my))?\s+"# + media)
    private static let playPattern = regex(#"(?:play|resume|unpause)(?:\s+(?:the|my|some))?(?:\s+"# + media + #")?|continue(?:\s+(?:the|my))?\s+"# + media)
    private static let nextPattern = regex(#"(?:play\s+)?(?:the\s+)?next\s+(?:song|track)|skip(?:\s+(?:this|the))?(?:\s+(?:song|track))?"#)
    private static let previousPattern = regex(#"(?:play\s+)?(?:the\s+)?(?:previous|last)\s+(?:song|track)|go\s+back\s+(?:a|one)\s+(?:song|track)"#)

    private static let setVolume = regex(#"(?:(?:set|turn|put)\s+)?(?:the\s+)?volume\s+(?:to\s+|at\s+)?(\d{1,3})\s*(?:%|percent)?"#)
    private static let volumeUp = regex(#"turn\s+(?:it|the\s+(?:volume|music|sound))\s+up|turn\s+up\s+the\s+(?:volume|music|sound)|volume\s+up|louder"#)
    private static let volumeDown = regex(#"turn\s+(?:it|the\s+(?:volume|music|sound))\s+down|turn\s+down\s+the\s+(?:volume|music|sound)|volume\s+down|quieter"#)
    private static let mute = regex(#"mute(?:\s+(?:it|the\s+(?:sound|audio|volume|mac)))?"#)
    private static let unmute = regex(#"unmute(?:\s+(?:it|the\s+(?:sound|audio|volume|mac)))?"#)

    private static let label = #"(?:\s+(?:for|called|named)\s+(?<label>.+))?"#
    private static let timerFor = regex(
        #"(?:(?:set|start|make)\s+)?(?:(?:a|an)\s+)?timer\s+for\s+(.+?)\s*(?<unit>seconds?|secs?|minutes?|mins?|hours?|hrs?)"# + label
    )
    private static let timerAfter = regex(
        #"(?:(?:set|start|make)\s+)?(?:(?:a|an)\s+)?([a-z0-9]+)[\s-](?<unit>second|sec|minute|min|hour|hr)\s+timer"# + label
    )

    private static let numberWords = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "twenty five": 25, "twenty-five": 25, "thirty": 30, "forty": 40,
        "forty five": 45, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    private static func seconds(_ amount: String, unit: String) -> Int? {
        let lower = unit.lowercased()
        let unitSeconds = lower.hasPrefix("h") ? 3600 : lower.hasPrefix("m") ? 60 : 1
        let words = amount.lowercased()
        if words == "half an" || words == "half a" { return unitSeconds / 2 }
        guard let count = Int(words) ?? numberWords[words], count > 0 else { return nil }
        return count * unitSeconds
    }

    private static let timePattern = regex(#"(?:what(?:'s| is)\s+the\s+time|what\s+time\s+is\s+it)(?:\s+(?:now|right now))?"#)
    private static let datePattern = regex(#"(?:what(?:'s| is)\s+(?:the\s+date|today's\s+date)|what\s+day\s+is\s+it)(?:\s+today)?"#)

    // MARK: Acting

    /// What to run (nil when the answer needs no action).
    public var action: AgentAction? {
        switch self {
        case .openApp(let name): return .openApp(name)
        case .openWebsite(let url, nil): return .openURL(url)
        case .openWebsite(let url, let browser?):
            return .appleScript("tell application \"\(browser)\"\nactivate\nopen location \"\(url)\"\nend tell")
        case .play, .pause: return .media("play_pause")
        case .next: return .media("next")
        case .previous: return .media("previous")
        case .setVolume(let level): return .appleScript("set volume output volume \(level)")
        case .changeVolume(let up):
            return .appleScript("set volume output volume ((output volume of (get volume settings)) \(up ? "+" : "-") 12)")
        case .mute(let on): return .appleScript("set volume \(on ? "with" : "without") output muted")
        case .timer(let seconds, let label): return .setTimer(seconds: seconds, label: label)
        case .time, .date: return nil
        }
    }

    /// What ZOOBIE says once the action ran. nil when it failed: the model takes the request over.
    public func reply(to output: String, now: Date = .now) -> String? {
        let failed = ["Error", "Couldn't", "Failed", "Unknown", "AppleScript", "Unsupported"].contains { output.hasPrefix($0) }
        if failed { return nil }
        switch self {
        case .openApp(let name): return name.hasSuffix("s") ? "\(name) is open." : "\(name)'s open."
        case .openWebsite(let url, _):
            let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
            return "\(host) is open."
        case .play: return "Playing."
        case .pause: return "Paused."
        case .next: return "Skipped."
        case .previous: return "Back one song."
        case .setVolume(let level): return "Volume's at \(level)."
        case .changeVolume(let up): return up ? "Turned it up." : "Turned it down."
        case .mute(let on): return on ? "Muted." : "Unmuted."
        case .timer(let seconds, let label):
            let name = label == "Timer" ? "Timer" : label.prefix(1).uppercased() + label.dropFirst() + " timer"
            return "\(name) set for \(Self.spoken(seconds))."
        case .time: return "It's \(Self.format(now, "h:mm a"))."
        case .date: return "It's \(Self.format(now, "EEEE, MMMM d"))."
        }
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// "10 minutes", "1 hour 30 minutes", "45 seconds".
    static func spoken(_ seconds: Int) -> String {
        func part(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        return [hours > 0 ? part(hours, "hour") : nil, minutes > 0 ? part(minutes, "minute") : nil, rest > 0 ? part(rest, "second") : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}
