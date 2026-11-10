import PDFKit
import XCTest
@testable import PaperplaneCore

final class PageToolsTests: XCTestCase {
    private let media = CGRect(x: 0, y: 0, width: 612, height: 792)

    func testCropBoxFollowsTheShownEdges() throws {
        let margins = PageMargins(top: 10, right: 20, bottom: 30, left: 40)
        XCTAssertEqual(PageCropper.cropBox(mediaBox: media, rotation: 0, margins: margins), CGRect(x: 40, y: 30, width: 552, height: 752))
        // Turned 90° clockwise, the page's left edge is shown on top.
        XCTAssertEqual(PageCropper.cropBox(mediaBox: media, rotation: 90, margins: margins), CGRect(x: 10, y: 40, width: 572, height: 732))
        for rotation in [0, 90, 180, 270] {
            let box = try XCTUnwrap(PageCropper.cropBox(mediaBox: media, rotation: rotation, margins: margins))
            XCTAssertEqual(PageCropper.margins(mediaBox: media, cropBox: box, rotation: rotation), margins, "rotation \(rotation)")
        }
        XCTAssertNil(PageCropper.cropBox(mediaBox: media, rotation: 0, margins: PageMargins(top: 400, bottom: 400)))
        XCTAssertNil(PageCropper.cropBox(mediaBox: media, rotation: 0, margins: PageMargins(top: 500, bottom: 400)), "Overlapping margins are refused.")
        XCTAssertNil(PageCropper.cropBox(mediaBox: media, rotation: 90, margins: PageMargins(right: 700, left: 200)))
    }

    func testContentMarginsTrimWhiteSpace() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixture("markup-regression.pdf")))
        let page = try XCTUnwrap(document.page(at: 0))
        let margins = try XCTUnwrap(PageCropper.contentMargins(of: page))
        // Three lines of text near the top left, from x 70 and y 626-734.
        XCTAssertLessThan(margins.top, 80)
        XCTAssertGreaterThan(margins.bottom, 500)
        XCTAssertGreaterThan(margins.left, 50)
        XCTAssertLessThan(margins.left, 72)
        XCTAssertEqual(page.rotation, 0, "The page's rotation is restored.")
        page.rotation = 90
        let turned = try XCTUnwrap(PageCropper.contentMargins(of: page))
        XCTAssertEqual(turned.right, margins.top, accuracy: 0.5)
        XCTAssertEqual(page.rotation, 90)
    }

    func testSplitGroups() throws {
        XCTAssertEqual(DocumentSplitter.groups(every: 3, pageCount: 7), [[0, 1, 2], [3, 4, 5], [6]])
        XCTAssertEqual(try DocumentSplitter.groups(from: "1-2，5, 3-", pageCount: 6), [[0, 1], [4], [2, 3, 4, 5]])
        XCTAssertThrowsError(try DocumentSplitter.groups(from: "4-9", pageCount: 6))
        XCTAssertEqual(DocumentSplitter.label(for: [2, 3, 4]), "3-5")
        XCTAssertEqual(DocumentSplitter.label(for: [0]), "1")
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }
}
