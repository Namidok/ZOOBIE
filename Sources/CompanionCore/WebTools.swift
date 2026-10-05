import Foundation

/// Web search and page reading for the local brain, which has no built-in web tools (Claude's run on
/// Anthropic's servers). Search uses DuckDuckGo's plain HTML page: no account or key, one request per
/// search, at a human pace.
public enum WebTools {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public struct SearchResult: Equatable, Sendable {
        public var title: String
        public var url: String
        public var snippet: String
    }

    /// The top results as numbered "title / URL / snippet" lines for the model.
    public static func search(_ query: String, limit: Int = 8) async -> String {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return "Error: the web search didn't go through (offline, or DuckDuckGo is limiting requests). Try again in a minute, or web_fetch a site you know."
        }
        let results = parseResults(String(decoding: data, as: UTF8.self)).prefix(limit)
        guard !results.isEmpty else { return "No results for \"\(query)\". Try different words." }
        return results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)\n   \($0.element.snippet)" }
            .joined(separator: "\n")
    }

    private static let titlePattern = try! NSRegularExpression(
        pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
    private static let snippetPattern = try! NSRegularExpression(
        pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])

    /// Results from DuckDuckGo's HTML page, each paired with the snippet that follows its title.
    static func parseResults(_ html: String) -> [SearchResult] {
        let ns = html as NSString
        let titles = titlePattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
        return titles.enumerated().compactMap { index, match in
            let url = resolve(ns.substring(with: match.range(at: 1)))
            guard url.hasPrefix("http"), !url.contains("duckduckgo.com/y.js") else { return nil } // skip ads
            let end = index + 1 < titles.count ? titles[index + 1].range.location : ns.length
            let tail = NSRange(location: match.range.upperBound, length: end - match.range.upperBound)
            let snippet = snippetPattern.firstMatch(in: html, range: tail).map { text(ns.substring(with: $0.range(at: 1))) } ?? ""
            return SearchResult(title: text(ns.substring(with: match.range(at: 2))), url: url, snippet: snippet)
        }
    }

    /// DuckDuckGo links go through a redirect (`//duckduckgo.com/l/?uddg=<target>`); return the target.
    static func resolve(_ href: String) -> String {
        let decoded = decodeEntities(href)
        let absolute = decoded.hasPrefix("//") ? "https:" + decoded : decoded
        if let components = URLComponents(string: absolute), let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return absolute
    }

    /// Reads a web page as plain text (title first), trimmed to `limit` characters.
    public static func fetch(_ address: String, limit: Int = 8000) async -> String {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "Error: only http(s) addresses can be read."
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
            return "Error: couldn't reach \(address)."
        }
        guard (200..<300).contains(http.statusCode) else { return "Error: \(address) answered HTTP \(http.statusCode)." }
        let raw = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        let isHTML = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html") || raw.prefix(500).lowercased().contains("<html")
        var body = isHTML ? pageText(raw) : raw
        if body.count > limit { body = String(body.prefix(limit)) + "\n… [page trimmed to \(limit) characters]" }
        return body.isEmpty ? "The page at \(address) has no readable text." : body
    }

    private static let titleTag = try! NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let dropped = try! NSRegularExpression(
        pattern: #"<(script|style|noscript|svg|head|template)\b[^>]*>.*?</\1>|<!--.*?-->"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let breaks = try! NSRegularExpression(pattern: #"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/header|/footer)\b[^>]*>"#, options: [.caseInsensitive])
    private static let bullets = try! NSRegularExpression(pattern: #"<li\b[^>]*>"#, options: [.caseInsensitive])
    private static let tags = try! NSRegularExpression(pattern: #"<[^>]+>"#)

    /// A page's readable text: the title, then the body without scripts, styles or tags.
    static func pageText(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        let title = titleTag.firstMatch(in: html, range: range).map { text((html as NSString).substring(with: $0.range(at: 1))) }
        var body = dropped.stringByReplacingMatches(in: html, range: range, withTemplate: " ")
        body = breaks.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "\n")
        body = bullets.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "\n• ")
        body = tags.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: " ")
        let lines = decodeEntities(body).components(separatedBy: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && $0 != "•" }
        return ([title.map { "# \($0)" }].compactMap { $0 } + lines).joined(separator: "\n")
    }

    /// Inline text: tags removed, entities decoded, whitespace collapsed.
    static func text(_ fragment: String) -> String {
        let stripped = tags.stringByReplacingMatches(in: fragment, range: NSRange(fragment.startIndex..., in: fragment), withTemplate: "")
        return decodeEntities(stripped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let numericEntity = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        let ns = out as NSString
        for match in numericEntity.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            let code = ns.substring(with: match.range(at: 1))
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let value, let scalar = Unicode.Scalar(value) {
                out = (out as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&") // last, so "&amp;lt;" stays "&lt;"
    }
}
