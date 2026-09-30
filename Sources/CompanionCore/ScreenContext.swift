import CoreGraphics
import Foundation

/// A line of text recognised on screen. `frame` is in AppKit global coordinates (bottom-left origin).
public struct TextElement: Sendable, Equatable {
    public var id: Int
    public var text: String
    public var frame: CGRect

    public init(id: Int, text: String, frame: CGRect) {
        self.id = id
        self.text = text
        self.frame = frame
    }
}

/// What the companion saw when the user invoked it. Lives in memory only.
public struct ScreenContext: Sendable {
    public var appName: String?
    public var windowTitle: String?
    public var elements: [TextElement]
    public var cursor: CGPoint
    /// Downscaled JPEG for a vision model, if one will be used.
    public var imageBase64: String?

    public init(appName: String?, windowTitle: String?, elements: [TextElement], cursor: CGPoint, imageBase64: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.elements = elements
        self.cursor = cursor
        self.imageBase64 = imageBase64
    }

    public var characterCount: Int { elements.reduce(0) { $0 + $1.text.count } }

    public func element(id: Int) -> TextElement? { elements.first { $0.id == id } }

    /// Sorts raw OCR lines into reading order (top-to-bottom, then left-to-right) and assigns ids.
    public static func orderedElements(_ raw: [(text: String, frame: CGRect)]) -> [TextElement] {
        let medianHeight: CGFloat = {
            let heights = raw.map(\.frame.height).sorted()
            return heights.isEmpty ? 10 : heights[heights.count / 2]
        }()
        let rowTolerance = max(medianHeight * 0.5, 2)
        let sorted = raw.sorted { a, b in
            if abs(a.frame.midY - b.frame.midY) > rowTolerance { return a.frame.midY > b.frame.midY }
            return a.frame.minX < b.frame.minX
        }
        return sorted.enumerated().map { TextElement(id: $0.offset + 1, text: $0.element.text, frame: $0.element.frame) }
    }

    /// Renders the `<screen>` block for the prompt. When the text exceeds `budget` characters,
    /// the lines nearest the cursor win — that's where the user's attention is.
    public func promptBlock(budget: Int = 6000) -> String {
        var kept = elements
        if characterCount > budget {
            let byDistance = elements.sorted { distance($0) < distance($1) }
            var used = 0
            var keepIDs = Set<Int>()
            for element in byDistance where used + element.text.count <= budget {
                used += element.text.count + 6
                keepIDs.insert(element.id)
            }
            kept = elements.filter { keepIDs.contains($0.id) }
        }
        var attributes = ""
        if let appName { attributes += " app=\"\(Self.escape(appName))\"" }
        if let windowTitle, !windowTitle.isEmpty { attributes += " window=\"\(Self.escape(windowTitle))\"" }
        if kept.count < elements.count { attributes += " trimmed=\"kept \(kept.count) of \(elements.count) lines nearest the cursor\"" }
        let body = kept.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
        return "<screen\(attributes)>\n\(body)\n</screen>"
    }

    private func distance(_ element: TextElement) -> CGFloat {
        let dx = max(element.frame.minX - cursor.x, 0, cursor.x - element.frame.maxX)
        let dy = max(element.frame.minY - cursor.y, 0, cursor.y - element.frame.maxY)
        // Vertical distance matters more: code and logs are read line by line.
        return dx * 0.3 + dy
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'")
    }
}

/// A `[POINT:id]` or `[POINT:id:label]` tag the model appends to direct the cursor buddy.
/// Either an OCR element id (`[POINT:12]`) or pixel coordinates in the screenshot (`[POINT:640,300:label]`).
public struct PointTag: Sendable, Equatable {
    public var elementID: Int?
    public var coordinates: CGPoint?
    public var label: String?

    public init(elementID: Int, label: String? = nil) {
        self.elementID = elementID
        self.label = label
    }

    public init(x: Double, y: Double, label: String? = nil) {
        self.coordinates = CGPoint(x: x, y: y)
        self.label = label
    }

    /// The tag as the model writes it.
    var tag: String {
        let target = elementID.map(String.init) ?? coordinates.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"
        return "[POINT:\(target)\(label.map { ":" + $0 } ?? "")]"
    }
}

/// One spoken sentence and the on-screen elements it refers to.
public struct NarrationStep: Sendable, Equatable {
    public var text: String
    public var points: [PointTag]

    public init(text: String, points: [PointTag] = []) {
        self.text = text
        self.points = points
    }
}

public struct CodeSnippet: Sendable, Equatable {
    public var language: String
    public var code: String

    public init(language: String, code: String) {
        self.language = language
        self.code = code
    }
}

public struct Narration: Sendable, Equatable {
    public var steps: [NarrationStep]
    public var code: [CodeSnippet]
}

public enum ReplyParsing {
    private static let pointPattern = try! NSRegularExpression(pattern: #"\s*\[POINT:\s*([^\]:]*)(?::([^\]]*))?\]"#, options: [.caseInsensitive])

    /// Removes point tags from the text and returns every valid one, in order.
    public static func extractPoints(from text: String) -> (clean: String, points: [PointTag]) {
        let ns = text as NSString
        var points: [PointTag] = []
        for match in pointPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            var label: String?
            if match.range(at: 2).location != NSNotFound {
                // Drop a trailing ":screenN" (multi-monitor hint) from the label.
                label = ns.substring(with: match.range(at: 2))
                    .replacingOccurrences(of: #":?screen\d+$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                if label?.isEmpty == true { label = nil }
            }
            if let id = Int(target) {
                points.append(PointTag(elementID: id, label: label))
            } else if let (x, y) = coordinatePair(target) {
                points.append(PointTag(x: x, y: y, label: label))
            }
        }
        let clean = pointPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (clean.trimmingCharacters(in: .whitespacesAndNewlines), points)
    }

    /// Parses "640,300" (optionally spaced) into a pixel coordinate pair.
    public static func coordinatePair(_ text: String) -> (Double, Double)? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return (x, y)
    }

    /// Removes point tags from the visible reply and returns the first valid one.
    public static func extractPoint(from text: String) -> (clean: String, point: PointTag?) {
        let (clean, points) = extractPoints(from: text)
        return (clean, points.first)
    }

    /// Splits a (possibly still streaming) reply into spoken sentences — each carrying the screen
    /// elements it points at — plus code blocks to show. With `final == false` only sentences that
    /// can no longer change are returned, so callers can start speaking while the model is typing:
    /// the step count only ever grows and earlier steps never change.
    public static func narration(from text: String, final: Bool) -> Narration {
        var proseParts: [String] = []
        var code: [CodeSnippet] = []
        var buffer: [String] = []
        var inFence = false
        var language = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    code.append(CodeSnippet(language: language, code: buffer.joined(separator: "\n")))
                } else {
                    proseParts.append(buffer.joined(separator: "\n"))
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                buffer = []
                inFence.toggle()
                continue
            }
            buffer.append(String(line))
        }
        let endsInProse = !inFence
        if inFence {
            if final { code.append(CodeSnippet(language: language, code: buffer.joined(separator: "\n"))) }
        } else {
            proseParts.append(buffer.joined(separator: "\n"))
        }

        var pieces = proseParts.flatMap(sentencePieces)
        if !final && endsInProse, let last = pieces.popLast() {
            // The last piece may still be growing. It is also the only place a point tag belonging
            // to the previous sentence can appear ("Click Run. [POINT:3] Then…").
            let (lead, rest) = leadingTags(last)
            if rest.isEmpty || rest.hasPrefix("[") {
                _ = pieces.popLast()
            } else if !lead.isEmpty {
                pieces.append(lead.map(\.tag).joined())
            }
        }

        var steps: [NarrationStep] = []
        var carried: [PointTag] = []
        for piece in pieces {
            let (lead, rest) = leadingTags(piece)
            if steps.isEmpty { carried += lead } else { steps[steps.count - 1].points += lead }
            let (clean, points) = extractPoints(from: rest)
            let spoken = stripMarkdown(clean)
            guard spoken.contains(where: { $0.isLetter || $0.isNumber }) else {
                if steps.isEmpty { carried += points } else { steps[steps.count - 1].points += points }
                continue
            }
            steps.append(NarrationStep(text: spoken, points: carried + points))
            carried = []
        }
        return Narration(steps: steps, code: code.filter { !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    /// Lines, then sentences within a line (a terminator followed by whitespace, so "file.txt" stays whole).
    private static func sentencePieces(_ prose: String) -> [String] {
        prose.split(separator: "\n").flatMap { line in
            // Drop list markers first so "1. Open the terminal." isn't split into "1." + "Open…".
            line.replacingOccurrences(of: #"^\s*(\d+[.)]|[-*+])\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\u{1}", options: .regularExpression)
                .split(separator: "\u{1}")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { !$0.isEmpty }
    }

    private static let leadingTagPattern = try! NSRegularExpression(pattern: #"^(\s*\[POINT:[^\]]*\])+"#, options: [.caseInsensitive])

    private static func leadingTags(_ piece: String) -> (tags: [PointTag], rest: String) {
        let range = NSRange(piece.startIndex..., in: piece)
        guard let match = leadingTagPattern.firstMatch(in: piece, range: range), let tagRange = Range(match.range, in: piece) else {
            return ([], piece)
        }
        return (extractPoints(from: String(piece[tagRange])).points,
                String(piece[tagRange.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    static func stripMarkdown(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|\*|`)"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

public enum VisionRouting {
    private static let visualWords = try! NSRegularExpression(
        pattern: #"\b(look|looks|see|image|picture|photo|diagram|chart|graph|design|layout|color|colour|icon|button|screenshot|ui|visual)\b"#,
        options: [.caseInsensitive]
    )

    /// Decides whether this question should go to the (slower) vision model instead of OCR text.
    public static func shouldUseVision(mode: VisionMode, hasVisionModel: Bool, ocrCharacters: Int, question: String, sparseThreshold: Int = 150) -> Bool {
        guard hasVisionModel else { return false }
        switch mode {
        case .never: return false
        case .always: return true
        case .auto:
            if ocrCharacters < sparseThreshold { return true }
            let range = NSRange(question.startIndex..., in: question)
            return visualWords.firstMatch(in: question, range: range) != nil
        }
    }
}
