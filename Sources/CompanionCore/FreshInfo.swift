import Foundation

/// Questions whose answer depends on today — events, weather, news, prices, opening hours. The local
/// model's knowledge is months old and it rarely decides to search on its own, so the agent loop
/// searches first and hands it the results with the question.
public enum FreshInfo {
    /// Asking about the user's own things ("what's on my calendar today", "remind me tomorrow"):
    /// tools answer those, the web can't.
    private static let personal = words([
        "calendar", "meetings?", "appointments?", "remind(?:er)?s?", "timers?", "alarms?", "notes?", "e-?mails?", "inbox",
        "files?", "folders?", "desktop", "screen", "code", "errors?", #"my\s+(?:schedule|day|week|tasks?|notebook)"#,
    ])

    private static let timely = words([
        #"right\s+now"#, "today", "tonight", "tomorrow", #"this\s+(?:weekend|week|evening|morning|afternoon|month|year)"#,
        "currently", "latest", "recent(?:ly)?", "news", "weather", "forecast", "temperature", #"open\s+now"#,
        #"opening\s+hours"#, "events?", "happening", "concerts?", "prices?", "costs?", "stock", #"exchange\s+rate"#,
        "scores?", #"who\s+won"#, "results?", #"release\s+date"#, "trending",
    ])

    private static func words(_ alternatives: [String]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"\b(?:"# + alternatives.joined(separator: "|") + #")\b"#, options: [.caseInsensitive])
    }

    /// Politeness and the like at the start ("hey", "can you", "please"); the time words at the end stay.
    private static let fillers = try! NSRegularExpression(
        pattern: #"^(?:(?:hey|hi|okay|ok|so|um|uh|please|just|can you|could you|would you|will you)[ ,]+)+"#, options: [.caseInsensitive])

    private static let leadIns = try! NSRegularExpression(
        pattern: #"^(?:(?:give|tell|show|find|get)\s+me|search(?:\s+for)?|look\s+up|find)\s+"#, options: [.caseInsensitive])

    /// The web search to run before answering, or nil when the request doesn't need current facts.
    /// `names` are the agent names the user may address ("Zoobs, …"), left out of the query.
    public static func query(for request: String, names: [String] = []) -> String? {
        let range = NSRange(request.startIndex..., in: request)
        guard timely.firstMatch(in: request, range: range) != nil, personal.firstMatch(in: request, range: range) == nil else { return nil }
        var text = request
        for name in names where !name.isEmpty {
            text = text.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b,?", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
        text = fillers.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = leadIns.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let query = text.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : query
    }

    /// The results as context for the model, with today's date so "now" means something.
    public static func briefing(results: String, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        return """
        <web_results searched="\(formatter.string(from: now))">
        \(results)
        </web_results>
        It is \(formatter.string(from: now)). Answer from these results: name the specific places, events or facts \
        they give, with dates where they have them. If they don't cover the question, say so — never present \
        remembered facts as current.
        """
    }
}
