import Foundation

/// ZOOBIE's four fixed, persistent specialist agents. Each has its own persona, toolset, notebook
/// (long-term memory it maintains itself) and conversation thread.
public struct Specialist: Sendable, Hashable, Identifiable {
    public enum ID: String, CaseIterable, Codable, Sendable {
        case jobs, mentor, schedule, german
    }

    public let id: ID
    /// Shown until the user picks their own name.
    public let defaultName: String
    public let role: String
    public let persona: String
    /// Client tools this specialist may use (web search/fetch are added for all of them).
    public let tools: Set<String>
    public let effort: String
    /// SF Symbol used until the user supplies an avatar.
    public let symbol: String

    public static let all: [Specialist] = [
        Specialist(
            id: .jobs, defaultName: "Job Hunter",
            role: "Finds job and internship listings, tracks applications, and writes tailored CVs and cover letters.",
            persona: "Methodical and career-focused. You produce structured Markdown: tables for listings and trackers, clear next steps, deadlines first.",
            tools: ["read_file", "write_file", "list_directory", "run_shell", "open_url", "update_notebook"],
            effort: "medium", symbol: "briefcase.fill"
        ),
        Specialist(
            id: .mentor, defaultName: "Dev Mentor",
            role: "A senior engineer and AI/ML teaching assistant for software development, Python/FastAPI, machine learning and academic assignments.",
            persona: "Analytical and precise, with architectural-grade guidance. You teach rather than just hand over answers: explain the why, show the minimal correct code, and point out pitfalls.",
            tools: ["read_file", "write_file", "list_directory", "run_shell", "open_url", "update_notebook"],
            effort: "medium", symbol: "chevron.left.forwardslash.chevron.right"
        ),
        Specialist(
            id: .schedule, defaultName: "Scheduler",
            role: "Runs daily logistics: calendar, reminders, timers and quick administrative lookups.",
            persona: "An efficient, highly organized, proactive secretary. Confirm what you scheduled with exact dates and times, and flag conflicts.",
            tools: ["set_timer", "list_timers", "cancel_timer", "create_reminder", "list_events", "create_event", "run_applescript", "open_url", "update_notebook"],
            effort: "low", symbol: "calendar"
        ),
        Specialist(
            id: .german, defaultName: "German Tutor",
            role: "A dedicated German language coach: grammar, vocabulary and conversational practice in both German and English.",
            persona: "Patient, structured and encouraging. Pitch German at the learner's level (track it in your notebook), correct mistakes gently by showing the corrected sentence and a one-line why, and keep practice conversational.",
            tools: ["read_file", "write_file", "open_url", "update_notebook"],
            effort: "low", symbol: "character.book.closed.fill"
        ),
    ]

    public static func get(_ id: ID) -> Specialist { all.first { $0.id == id }! }

    /// Matches loose names the model might use ("job hunter", "german", "scheduler"…).
    public static func resolve(_ name: String) -> Specialist? {
        let key = name.lowercased().filter(\.isLetter)
        if let id = ID(rawValue: key) { return get(id) }
        if key.contains("job") || key.contains("resume") || key.contains("career") || key.contains("intern") { return get(.jobs) }
        if key.contains("dev") || key.contains("mentor") || key.contains("code") || key.contains("ml") { return get(.mentor) }
        if key.contains("sched") || key.contains("calendar") || key.contains("remind") || key.contains("timer") || key.contains("life") { return get(.schedule) }
        if key.contains("german") || key.contains("deutsch") || key.contains("tutor") || key.contains("language") { return get(.german) }
        return nil
    }
}

// MARK: - Memory

/// Each specialist's notebook (Markdown it rewrites itself) and recent conversation, kept in
/// ~/Library/Application Support/Companion/agents/<id>/. Text only — never screenshots or audio.
public struct SpecialistStore: Sendable {
    public var directory: URL
    public static let threadLimit = 40

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Companion/agents")) {
        self.directory = directory
    }

    private func folder(_ id: Specialist.ID) -> URL {
        let url = directory.appendingPathComponent(id.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func notebookURL(_ id: Specialist.ID) -> URL { folder(id).appendingPathComponent("notebook.md") }

    public func notebook(_ id: Specialist.ID) -> String {
        (try? String(contentsOf: notebookURL(id), encoding: .utf8)) ?? ""
    }

    public func thread(_ id: Specialist.ID) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("thread.json")) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    public func append(_ messages: [ChatMessage], to id: Specialist.ID) {
        var thread = thread(id) + messages
        if thread.count > Self.threadLimit { thread.removeFirst(thread.count - Self.threadLimit) }
        if let data = try? JSONEncoder().encode(thread) {
            try? data.write(to: folder(id).appendingPathComponent("thread.json"), options: .atomic)
        }
    }

    /// Forgets the conversation and the notebook.
    public func clear(_ id: Specialist.ID) {
        try? FileManager.default.removeItem(at: folder(id).appendingPathComponent("thread.json"))
        try? FileManager.default.removeItem(at: notebookURL(id))
    }
}

// MARK: - Dates & Apple apps

public enum LocalDate {
    /// Parses what models write: "2026-10-02T18:00", "2026-10-02 18:00", "2026-10-02T18:00:00Z", "2026-10-02".
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    public static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// AppleScript for Calendar and Reminders, built from structured values so the model never has to
/// get AppleScript date syntax (which depends on the system locale) right.
public enum AppleAppScripts {
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Builds a date variable without parsing strings: `set d to current date` and then each component.
    static func dateVariable(_ name: String, _ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return """
        set \(name) to current date
        set day of \(name) to 1
        set year of \(name) to \(c.year!)
        set month of \(name) to \(c.month!)
        set day of \(name) to \(c.day!)
        set time of \(name) to \(c.hour! * 3600 + c.minute! * 60)
        """
    }

    public static func createReminder(title: String, due: Date?, notes: String?) -> String {
        var properties = "name:\(quote(title))"
        if let notes, !notes.isEmpty { properties += ", body:\(quote(notes))" }
        var script = ""
        if let due {
            script += dateVariable("dueDate", due) + "\n"
            properties += ", due date:dueDate, remind me date:dueDate"
        }
        script += "tell application \"Reminders\" to make new reminder with properties {\(properties)}\nreturn \"Reminder created.\""
        return script
    }

    public static func listEvents(from: Date, to: Date) -> String {
        dateVariable("startRange", from) + "\n" + dateVariable("endRange", to) + """

        set output to ""
        tell application "Calendar"
            repeat with cal in calendars
                set found to (every event of cal whose start date ≥ startRange and start date < endRange)
                repeat with ev in found
                    set output to output & (start date of ev as string) & " — " & (summary of ev) & " [" & (name of cal) & "]" & linefeed
                end repeat
            end repeat
        end tell
        if output is "" then return "No events in that range."
        return output
        """
    }

    public static func createEvent(title: String, start: Date, end: Date, location: String?) -> String {
        var properties = "summary:\(quote(title)), start date:startDate, end date:endDate"
        if let location, !location.isEmpty { properties += ", location:\(quote(location))" }
        return dateVariable("startDate", start) + "\n" + dateVariable("endDate", end) + """

        tell application "Calendar"
            set target to first calendar whose writable is true
            make new event at end of events of target with properties {\(properties)}
        end tell
        return "Event created."
        """
    }
}
