import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import PaperplaneCore

final class DocumentConverterTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }

    func testTextFormats() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixture("cjk-mixed-layout.pdf")))
        let plain = String(decoding: try DocumentConverter.textData(of: document, format: .plainText), as: UTF8.self)
        XCTAssertTrue(plain.contains("中文字体测试") && plain.contains("日本語"))

        let rich = try DocumentConverter.textData(of: document, format: .richText)
        let readRich = try NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(readRich.string.contains("中文字体测试"))
        let font = try XCTUnwrap(readRich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 18, accuracy: 0.5, "Font sizes are kept.")

        let word = try DocumentConverter.textData(of: document, format: .word)
        let readWord = try NSAttributedString(data: word, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(readWord.string.contains("한국어"))
    }

    func testPagesAreSeparated() throws {
        let source = try XCTUnwrap(PDFDocument(url: fixture("markup-regression.pdf")))
        let document = PDFDocument()
        for index in 0..<2 { document.insert(try XCTUnwrap(source.page(at: 0)?.copy() as? PDFPage), at: index) }
        let rich = String(decoding: try DocumentConverter.textData(of: document, format: .richText), as: UTF8.self)
        XCTAssertEqual(rich.components(separatedBy: "\\page").count, 2, "One page break between two pages.")
        let one = String(decoding: try DocumentConverter.textData(of: document, pages: [1], format: .plainText), as: UTF8.self)
        XCTAssertEqual(one.components(separatedBy: "Select this text").count, 2)
    }

    func testScannedPagesHaveNoText() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixture("scanned-image-only.pdf")))
        for format in TextExportFormat.allCases {
            XCTAssertThrowsError(try DocumentConverter.textData(of: document, format: format)) { error in
                XCTAssertEqual(error as? DocumentConversionError, .noText)
            }
        }
    }

    func testImagePages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paperplane-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func image(_ name: String, type: UTType = .jpeg, width: Int, height: Int, orientation: Int, dpi: Double) throws -> URL {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let url = folder.appendingPathComponent(name)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                       [kCGImagePropertyOrientation: orientation, kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }
        // 1200×600 pixels stored turned: shown 600×1200.
        let turned = try image("turned.jpg", width: 1200, height: 600, orientation: 6, dpi: 72)
        XCTAssertEqual(try DocumentConverter.page(fromImageAt: turned, size: .image).bounds(for: .mediaBox).size, CGSize(width: 600, height: 1200))
        // The resolution sets the size: 144 dpi is half the points.
        let sharp = try image("sharp.png", type: .png, width: 1200, height: 600, orientation: 1, dpi: 144)
        XCTAssertEqual(try DocumentConverter.page(fromImageAt: sharp, size: .image).bounds(for: .mediaBox).size, CGSize(width: 600, height: 300))
        XCTAssertEqual(try DocumentConverter.page(fromImageAt: turned, size: .a4).bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
        let wide = try image("wide.jpg", width: 1200, height: 600, orientation: 1, dpi: 72)
        XCTAssertEqual(try DocumentConverter.page(fromImageAt: wide, size: .letter).bounds(for: .mediaBox).size, CGSize(width: 792, height: 612))
        XCTAssertThrowsError(try DocumentConverter.page(fromImageAt: fixture("markup-regression.pdf").deletingLastPathComponent().appendingPathComponent("manifest.json"), size: .a4))
    }
}
