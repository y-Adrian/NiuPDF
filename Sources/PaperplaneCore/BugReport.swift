import Foundation

/// A bug report as plain text: what the user wrote, then details of the Mac,
/// the app and the open document, a crash report if there was one, and the
/// app's log. The whole text is what is copied or saved; an email or an issue
/// page gets a shortened text when the whole one is too long for a link.
public struct BugReport: Equatable, Sendable {
    /// A titled list of name–value lines, such as "System" or "Document".
    public struct Section: Equatable, Sendable {
        public var title: String
        public var lines: [(name: String, value: String)]

        public init(title: String, lines: [(name: String, value: String)]) {
            self.title = title
            self.lines = lines
        }

        public static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.title == rhs.title && lhs.lines.map(\.name) == rhs.lines.map(\.name) && lhs.lines.map(\.value) == rhs.lines.map(\.value)
        }
    }

    public var summary: String
    public var steps: String
    public var sections: [Section]
    public var crash: String?
    /// Oldest first.
    public var log: [String]

    public init(summary: String, steps: String = "", sections: [Section] = [], crash: String? = nil, log: [String] = []) {
        self.summary = summary
        self.steps = steps
        self.sections = sections
        self.crash = crash
        self.log = log
    }

    /// The first line of the summary, at most 80 characters.
    public var title: String {
        let line = summary.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Bug report" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// The whole report.
    public var text: String { text(logLines: log.count, includesCrash: true) }

    /// The report in at most `limit` characters: the oldest log lines go
    /// first, then the crash report; what the user wrote and the details are
    /// always kept. `nil` when even those are too long.
    public func text(limit: Int) -> (text: String, isShortened: Bool)? {
        let whole = text
        if whole.count <= limit { return (whole, false) }
        for includesCrash in crash == nil ? [true] : [true, false] {
            // The most log lines that fit, by halving.
            var low = 0, high = log.count
            while low < high {
                let middle = (low + high + 1) / 2
                if text(logLines: middle, includesCrash: includesCrash, shortened: true).count <= limit { low = middle } else { high = middle - 1 }
            }
            let made = text(logLines: low, includesCrash: includesCrash, shortened: true)
            if made.count <= limit { return (made, true) }
        }
        return nil
    }

    private func text(logLines: Int, includesCrash: Bool, shortened: Bool = false) -> String {
        var parts: [String] = []
        parts.append("## What happened\n\n" + nonEmpty(summary))
        if !steps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("## Steps to reproduce\n\n" + steps.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for section in sections where !section.lines.isEmpty {
            parts.append("## \(section.title)\n\n" + section.lines.map { "- \($0.name): \($0.value)" }.joined(separator: "\n"))
        }
        if let crash, includesCrash {
            parts.append("## Crash\n\n```\n\(crash)\n```")
        }
        if !log.isEmpty {
            let kept = log.suffix(logLines)
            var heading = "## Log"
            if kept.count < log.count { heading += " (last \(kept.count) of \(log.count) lines)" }
            parts.append(kept.isEmpty ? heading + "\n\n(left out)" : heading + "\n\n```\n" + kept.joined(separator: "\n") + "\n```")
        }
        if shortened {
            parts.append("(This report was shortened. The whole report is on the clipboard; paste it here.)")
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private func nonEmpty(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(not described)" : trimmed
    }

    /// A new-issue page, as GitHub's: `issues` is the issues page, such as
    /// https://github.com/owner/repo/issues.
    public func issueURL(issues: URL, limit: Int = 6000) -> (url: URL, isShortened: Bool)? {
        guard let body = text(limit: limit) else { return nil }
        var components = URLComponents(url: issues.appendingPathComponent("new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body.text)]
        return components?.url.map { ($0, body.isShortened) }
    }

    /// A `mailto:` link; mail apps take bodies of a few thousand characters.
    public func mailURL(to address: String, subjectPrefix: String = "[Paperplane] ", limit: Int = 4000) -> (url: URL, isShortened: Bool)? {
        guard let body = text(limit: limit) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [URLQueryItem(name: "subject", value: subjectPrefix + title), URLQueryItem(name: "body", value: body.text)]
        // `+` is a space in some mail apps; spell it out.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url.map { ($0, body.isShortened) }
    }
}
