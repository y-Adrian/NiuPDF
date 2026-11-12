import XCTest
@testable import PaperplaneCore

final class BugReportTests: XCTestCase {
    private func report(logLines: Int = 400, crash: String? = nil) -> BugReport {
        BugReport(
            summary: "Saving loses highlights\nSecond line of the description",
            steps: "1. Highlight text\n2. Press ⌘S",
            sections: [.init(title: "System", lines: [("macOS", "27.2"), ("App", "1.0 (1)")])],
            crash: crash,
            log: (1...max(logLines, 1)).prefix(logLines).map { String(format: "12:00:%02d open line %d with some words", $0 % 60, $0) }
        )
    }

    func testWholeTextHasEverySection() {
        let text = report(logLines: 3, crash: "EXC_BAD_ACCESS").text
        for part in ["## What happened", "Saving loses highlights", "## Steps to reproduce", "Press ⌘S",
                     "## System", "- macOS: 27.2", "## Crash", "EXC_BAD_ACCESS", "## Log", "open line 3"] {
            XCTAssertTrue(text.contains(part), part)
        }
        XCTAssertFalse(text.contains("shortened"))
        XCTAssertEqual(report().title, "Saving loses highlights")
        XCTAssertEqual(BugReport(summary: "  ").title, "Bug report")
        XCTAssertFalse(BugReport(summary: "x").text.contains("## Steps"))
    }

    func testShortenedTextKeepsTheNewestLogLines() throws {
        let whole = report()
        let short = try XCTUnwrap(whole.text(limit: 3000))
        XCTAssertTrue(short.isShortened)
        XCTAssertLessThanOrEqual(short.text.count, 3000)
        XCTAssertTrue(short.text.contains("open line 400 "))
        XCTAssertFalse(short.text.contains("open line 1 "))
        XCTAssertTrue(short.text.contains("Saving loses highlights"))
        XCTAssertTrue(short.text.contains("of 400 lines"))
        // A text that fits is left whole.
        XCTAssertEqual(whole.text(limit: 1_000_000)?.isShortened, false)
    }

    func testCrashGoesWhenTheDetailsAloneFit() throws {
        let crash = String(repeating: "frame 0x0000 Paperplane\n", count: 200)
        let short = try XCTUnwrap(report(logLines: 10, crash: crash).text(limit: 2000))
        XCTAssertFalse(short.text.contains("## Crash"))
        XCTAssertTrue(short.text.contains("## System"))
        XCTAssertNil(BugReport(summary: String(repeating: "a", count: 500)).text(limit: 100))
    }

    func testLinksCarryTitleAndBody() throws {
        let issues = try XCTUnwrap(URL(string: "https://github.com/someone/paperplane/issues"))
        let issue = try XCTUnwrap(report().issueURL(issues: issues))
        let components = try XCTUnwrap(URLComponents(url: issue.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/someone/paperplane/issues/new")
        XCTAssertEqual(components.queryItems?.first { $0.name == "title" }?.value, "Saving loses highlights")
        XCTAssertTrue(issue.isShortened)

        let mail = try XCTUnwrap(BugReport(summary: "1+1 is wrong & more").mailURL(to: "help@example.com"))
        XCTAssertTrue(mail.url.absoluteString.hasPrefix("mailto:help@example.com?subject="))
        XCTAssertFalse(mail.url.absoluteString.contains("+"))
        let body = URLComponents(url: mail.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value
        XCTAssertTrue(body?.contains("1+1 is wrong & more") == true)
        XCTAssertFalse(mail.isShortened)
    }
}
