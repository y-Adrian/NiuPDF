import AppKit
import PDFKit

/// Redacting: what is under the redacted areas is removed from the page, not
/// only covered. PDFKit cannot edit a page's content, so the page becomes a
/// picture of itself with the areas filled black; its text can be recognized
/// again (`TextRecognizer`), so the rest stays searchable.
public enum Redactor {
    /// A new page: the page's content (not its annotations) as an image at
    /// `dpi`, with `areas` (page space) black. Boxes, crop and rotation are
    /// the page's. With `recognizingText`, the text left is added back as an
    /// invisible layer.
    public static func redactedPage(from page: PDFPage, areas: [CGRect], dpi: CGFloat = 300, recognizingText: Bool) throws -> PDFPage {
        guard let source = page.pageRef else { throw DocumentExportError.unableToWrite }
        let mediaBox = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let width = Int((mediaBox.width * scale).rounded()), height = Int((mediaBox.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw DocumentExportError.unableToWrite }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        context.drawPDFPage(source)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for area in areas { context.fill(area) }
        guard let image = context.makeImage() else { throw DocumentExportError.unableToWrite }

        // The picture as the whole page, compressed as JPEG.
        var box = mediaBox
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
              let provider = CGDataProvider(data: jpeg as CFData),
              let compressed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw DocumentExportError.unableToWrite
        }
        pdf.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        pdf.draw(compressed, in: mediaBox)
        pdf.endPDFPage()
        pdf.closePDF()
        guard let made = PDFDocument(data: data as Data)?.page(at: 0) else { throw DocumentExportError.unableToWrite }
        made.setBounds(page.bounds(for: .cropBox), for: .cropBox)
        made.rotation = page.rotation
        guard recognizingText else { return made }
        let lines = try TextRecognizer.recognize(made)
        return TextRecognizer.searchablePage(from: made, lines: lines) ?? made
    }
}
