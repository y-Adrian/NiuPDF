import XCTest
@testable import PaperplaneCore

final class PageMarkLayoutTests: XCTestCase {
    private let box = CGRect(x: 10, y: 20, width: 600, height: 800)

    func testShownSpaceFollowsRotation() {
        // The shown bottom-left corner, and the shown "up" direction, in page space.
        let expected: [Int: (origin: CGPoint, up: CGPoint)] = [
            0: (CGPoint(x: 10, y: 20), CGPoint(x: 0, y: 1)),
            // Turned clockwise: the page's left edge is shown on top.
            90: (CGPoint(x: 610, y: 20), CGPoint(x: -1, y: 0)),
            180: (CGPoint(x: 610, y: 820), CGPoint(x: 0, y: -1)),
            270: (CGPoint(x: 10, y: 820), CGPoint(x: 1, y: 0))
        ]
        for (rotation, want) in expected {
            let layout = PageMarkLayout(cropBox: box, rotation: rotation)
            let origin = CGPoint.zero.applying(layout.transform)
            let up = CGPoint(x: 0, y: 1).applying(layout.transform)
            XCTAssertEqual(origin.x, want.origin.x, accuracy: 0.001, "rotation \(rotation)")
            XCTAssertEqual(origin.y, want.origin.y, accuracy: 0.001, "rotation \(rotation)")
            XCTAssertEqual(up.x - origin.x, want.up.x, accuracy: 0.001, "rotation \(rotation)")
            XCTAssertEqual(up.y - origin.y, want.up.y, accuracy: 0.001, "rotation \(rotation)")
            // The whole shown page maps onto the crop box.
            let shown = CGRect(origin: .zero, size: layout.shownSize)
            XCTAssertEqual(layout.pageRect(shown), box, "rotation \(rotation)")
        }
        XCTAssertEqual(PageMarkLayout(cropBox: box, rotation: -90).rotation, 270)
        XCTAssertEqual(PageMarkLayout(cropBox: box, rotation: 90).shownSize, CGSize(width: 800, height: 600))
    }

    func testHeaderRects() {
        let layout = PageMarkLayout(cropBox: box, rotation: 0)
        let size = CGSize(width: 40, height: 12)
        XCTAssertEqual(layout.rect(for: .topLeft, size: size, margin: 20), CGRect(x: 20, y: 768, width: 40, height: 12))
        XCTAssertEqual(layout.rect(for: .bottomCenter, size: size, margin: 20), CGRect(x: 280, y: 20, width: 40, height: 12))
        XCTAssertEqual(layout.rect(for: .bottomRight, size: size, margin: 20), CGRect(x: 540, y: 20, width: 40, height: 12))
        // On a page turned 90°, a header sits along the page's left edge.
        let turned = PageMarkLayout(cropBox: box, rotation: 90)
        let header = turned.pageRect(turned.rect(for: .topCenter, size: size, margin: 20))
        XCTAssertEqual(header, CGRect(x: 30, y: 400, width: 12, height: 40))
    }

    func testTokens() {
        var settings = HeaderFooterSettings()
        settings.texts[.bottomCenter] = "Page {page} of {pages}"
        settings.texts[.topLeft] = "{file} – {date}"
        settings.firstNumber = 5
        settings.date = "2026/11/11"
        settings.fileName = "Report"
        XCTAssertEqual(settings.text(at: .bottomCenter, ordinal: 0, count: 3), "Page 5 of 7")
        XCTAssertEqual(settings.text(at: .bottomCenter, ordinal: 2, count: 3), "Page 7 of 7")
        XCTAssertEqual(settings.text(at: .topLeft, ordinal: 0, count: 3), "Report – 2026/11/11")
        XCTAssertEqual(settings.text(at: .topRight, ordinal: 0, count: 3), "")
        XCTAssertTrue(settings.isNumbered)
        XCTAssertFalse(settings.isEmpty)
        XCTAssertTrue(HeaderFooterSettings().isEmpty)
    }

    func testSettingsRoundTrip() throws {
        var header = HeaderFooterSettings()
        header.texts = [.bottomCenter: "{page}", .topRight: "页眉"]
        header.color = MarkColor(red: 1, green: 0, blue: 0.5)
        header.pages = "2-"
        XCTAssertEqual(try JSONDecoder().decode(HeaderFooterSettings.self, from: JSONEncoder().encode(header)), header)
        var watermark = WatermarkSettings()
        watermark.text = "机密"
        watermark.tiled = true
        XCTAssertEqual(try JSONDecoder().decode(WatermarkSettings.self, from: JSONEncoder().encode(watermark)), watermark)
        // Settings saved by a later version with fewer or more fields still read.
        let partial = try JSONDecoder().decode(WatermarkSettings.self, from: Data(#"{"text":"A","future":1}"#.utf8))
        XCTAssertEqual(partial.text, "A")
        XCTAssertEqual(partial.opacity, WatermarkSettings().opacity)
    }

    func testWatermarkCenters() {
        let layout = PageMarkLayout(cropBox: box, rotation: 0)
        let size = CGSize(width: 200, height: 60)
        XCTAssertEqual(layout.watermarkCenters(size: size, angle: 45, tiled: false), [CGPoint(x: 300, y: 400)])
        let tiles = layout.watermarkCenters(size: size, angle: 45, tiled: true)
        XCTAssertGreaterThan(tiles.count, 4)
        XCTAssertTrue(tiles.contains(CGPoint(x: 300, y: 400)), "One tile stays in the middle.")
        // Every corner of the page is near some tile.
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 0), CGPoint(x: 0, y: 800), CGPoint(x: 600, y: 800)] {
            XCTAssertTrue(tiles.contains { hypot($0.x - corner.x, $0.y - corner.y) < 250 }, "corner \(corner)")
        }
    }
}
