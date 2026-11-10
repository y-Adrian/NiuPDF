import AppKit
import PDFKit
import XCTest
@testable import PaperplaneCore

final class TextRecognitionTests: XCTestCase {
    /// A page that is only a picture of three lines of text.
    private func scannedPage() throws -> PDFPage {
        let size = NSSize(width: 1240, height: 1754)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let lines = ["Quarterly report for the reading app", "中文扫描件：识别文字测试", "第二段：可以搜索吗？Paperplane 2026"]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 120, y: 1500 - index * 120), withAttributes: [.font: NSFont.systemFont(ofSize: 54)])
        }
        image.unlockFocus()
        let jpeg = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .jpeg, properties: [:]))
        return try XCTUnwrap(PDFPage(image: try XCTUnwrap(NSImage(data: jpeg))))
    }

    private func render(_ page: PDFPage) -> [UInt8] {
        let width = 124, height = 175
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.scaleBy(x: CGFloat(width) / page.bounds(for: .mediaBox).width, y: CGFloat(height) / page.bounds(for: .mediaBox).height)
        page.draw(with: .mediaBox, to: context)
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    func testScannedPageBecomesSearchable() throws {
        for rotation in [0, 90] {
            let page = try scannedPage()
            page.rotation = rotation
            XCTAssertFalse(TextRecognizer.hasText(page))
            let lines = try TextRecognizer.recognize(page)
            XCTAssertEqual(lines.map(\.text), ["Quarterly report for the reading app", "中文扫描件：识别文字测试", "第二段：可以搜索吗？Paperplane 2026"],
                           "rotation \(rotation)")
            let made = try XCTUnwrap(TextRecognizer.searchablePage(from: page, lines: lines))
            XCTAssertEqual(made.rotation, rotation)
            XCTAssertEqual(made.bounds(for: .mediaBox), page.bounds(for: .mediaBox))

            let document = PDFDocument()
            document.insert(made, at: 0)
            let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
            let hit = try XCTUnwrap(reopened.findString("Paperplane", withOptions: []).first)
            XCTAssertEqual(reopened.findString("识别", withOptions: []).count, 1)
            // The selection lies over the word in the picture, in page space (x 120 + text width, y ≈ 1250).
            let bounds = hit.bounds(for: try XCTUnwrap(hit.pages.first))
            XCTAssertEqual(bounds.midY, 1287, accuracy: 25, "rotation \(rotation)")
            XCTAssertGreaterThan(bounds.width, bounds.height, "Along the line, rotation \(rotation)")

            // The page looks the same: the text is invisible.
            let before = render(page), after = render(try XCTUnwrap(reopened.page(at: 0)))
            let difference = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThan(difference, 40, "rotation \(rotation)")
        }
    }

    func testTextIsFoundInTheContent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try XCTUnwrap(PDFDocument(url: root.appendingPathComponent("TestCorpus/fixtures/markup-regression.pdf"))?.page(at: 0))
        let scan = try XCTUnwrap(PDFDocument(url: root.appendingPathComponent("TestCorpus/fixtures/scanned-image-only.pdf"))?.page(at: 0))
        XCTAssertTrue(TextRecognizer.hasText(text))
        XCTAssertFalse(TextRecognizer.hasText(scan))
        XCTAssertFalse(TextRecognizer.hasText(PDFPage()))
    }

    func testBlankPageHasNoLines() throws {
        let page = PDFPage()
        XCTAssertEqual(try TextRecognizer.recognize(page), [])
    }
}
