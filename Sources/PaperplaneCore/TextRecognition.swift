import AppKit
import CoreText
import PDFKit
import Vision

/// A line of text found on a page, in shown space (see `PageMarkLayout`):
/// its baseline from start to end, and its height. Lines can run in any
/// direction, as on a page scanned sideways.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var start: CGPoint
    public var end: CGPoint
    public var height: CGFloat

    public init(text: String, start: CGPoint, end: CGPoint, height: CGFloat) {
        self.text = text
        self.start = start
        self.end = end
        self.height = height
    }

    public var length: CGFloat { hypot(end.x - start.x, end.y - start.y) }
    public var angle: CGFloat { atan2(end.y - start.y, end.x - start.x) }
}

/// Text recognition for scanned pages: Vision reads the page as it is shown,
/// and the text goes into the page as an invisible layer, under the picture,
/// so it can be searched, selected and copied. PDFKit's own
/// `saveTextFromOCROption` adds nothing (macOS 27).
public enum TextRecognizer {
    /// Languages Vision tries, Chinese first; others are detected as well.
    public static let languages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

    /// Whether the page's content draws text. `PDFPage.string` is no test: in
    /// a `PDFView`, PDFKit reads pictures of text on the pages it shows and
    /// reports that text, but does not keep it in the file.
    public static func hasText(_ page: PDFPage) -> Bool {
        guard let source = page.pageRef else { return false }
        let stream = CGPDFContentStreamCreateWithPage(source)
        defer { CGPDFContentStreamRelease(stream) }
        return TextOperatorScanner.drawsText(stream, depth: 0)
    }

    /// The lines Vision reads on the page.
    public static func recognize(_ page: PDFPage) throws -> [RecognizedLine] {
        let layout = PageMarkLayout(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let shown = layout.shownSize
        guard shown.width > 0, shown.height > 0 else { return [] }
        // About 300 dpi for a letter page, at most 4000 pixels on the long side.
        let scale = min(4.2, 4000 / max(shown.width, shown.height))
        let width = Int(shown.width * scale), height = Int(shown.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // `draw(with:to:)` turns the page as shown.
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        if #available(macOS 13, *) { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            // Vision's corners are normalized, with the origin at the bottom
            // left, as shown space; they follow the text's direction.
            func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * shown.width, y: p.y * shown.height) }
            let start = point(observation.bottomLeft), end = point(observation.bottomRight), top = point(observation.topLeft)
            return RecognizedLine(text: text, start: start, end: end, height: hypot(top.x - start.x, top.y - start.y))
        }
    }

    /// A new page with the page's content (not its annotations) and the lines
    /// as invisible text, each stretched over its box. Boxes, rotation and
    /// crop are those of the page.
    public static func searchablePage(from page: PDFPage, lines: [RecognizedLine]) -> PDFPage? {
        guard let source = page.pageRef else { return nil }
        var mediaBox = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.saveGState()
        context.drawPDFPage(source)
        context.restoreGState()
        let layout = PageMarkLayout(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        context.concatenate(layout.transform)
        context.setTextDrawingMode(.invisible)
        for line in lines {
            draw(line, in: context)
        }
        context.endPDFPage()
        context.closePDF()
        guard let made = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        made.setBounds(page.bounds(for: .cropBox), for: .cropBox)
        made.rotation = page.rotation
        return made
    }

    private static func draw(_ line: RecognizedLine, in context: CGContext) {
        guard line.length > 0, line.height > 0 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, max(line.height * 0.85, 1), nil)
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        guard width > 0 else { return }
        context.saveGState()
        // Along the baseline, a little above the bottom of the box, stretched
        // to the line's length so selections cover the words in the picture.
        context.textMatrix = .identity
        context.translateBy(x: line.start.x, y: line.start.y)
        context.rotate(by: line.angle)
        context.translateBy(x: 0, y: line.height * 0.18)
        context.scaleBy(x: line.length / CGFloat(width), y: 1)
        context.textPosition = .zero
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}

/// Looks for text-showing operators in a content stream and the forms it draws.
private enum TextOperatorScanner {
    private final class State {
        var found = false
        var depth: Int
        let stream: CGPDFContentStreamRef
        init(stream: CGPDFContentStreamRef, depth: Int) {
            self.stream = stream
            self.depth = depth
        }
    }

    static func drawsText(_ stream: CGPDFContentStreamRef, depth: Int) -> Bool {
        guard depth < 8, let table = CGPDFOperatorTableCreate() else { return false }
        defer { CGPDFOperatorTableRelease(table) }
        let showText: CGPDFOperatorCallback = { _, info in
            guard let info else { return }
            Unmanaged<State>.fromOpaque(info).takeUnretainedValue().found = true
        }
        for name in ["Tj", "TJ", "'", "\""] { CGPDFOperatorTableSetCallback(table, name, showText) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard !state.found, CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(state.stream, "XObject", name) else { return }
            var form: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &form), let form, let dictionary = CGPDFStreamGetDictionary(form) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let inner = CGPDFContentStreamCreateWithStream(form, resources ?? dictionary, state.stream)
            defer { CGPDFContentStreamRelease(inner) }
            if TextOperatorScanner.drawsText(inner, depth: state.depth + 1) { state.found = true }
        }
        let state = State(stream: stream, depth: depth)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        _ = CGPDFScannerScan(scanner)
        return state.found
    }
}
