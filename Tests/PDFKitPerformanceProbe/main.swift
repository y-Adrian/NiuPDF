import AppKit
import Darwin
import Foundation
import PDFKit

@main
enum PDFKitPerformanceProbe {
    static func main() {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
            fail("Usage: PDFKitPerformanceProbe <input.pdf> [preview.png]")
        }
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let openStart = DispatchTime.now().uptimeNanoseconds
        guard let document = PDFDocument(url: inputURL), document.pageCount > 0 else {
            fail("PDFKit could not open the input: \(inputURL.lastPathComponent)")
        }
        let openMilliseconds = elapsedMilliseconds(since: openStart)

        let firstPageStart = DispatchTime.now().uptimeNanoseconds
        guard let firstPage = document.page(at: 0) else { fail("First page is unavailable.") }
        let firstPageImage = firstPage.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox)
        guard let imageData = firstPageImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: imageData) else {
            fail("First-page rasterization failed.")
        }
        if CommandLine.arguments.count == 3 {
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
            guard outputURL.standardizedFileURL != inputURL.standardizedFileURL,
                  !FileManager.default.fileExists(atPath: outputURL.path),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                fail("Preview output must be a new path distinct from the input.")
            }
            do { try png.write(to: outputURL, options: .atomic) }
            catch { fail("Could not write preview image: \(error)") }
        }
        let firstPageMilliseconds = elapsedMilliseconds(since: firstPageStart)

        let allPagesStart = DispatchTime.now().uptimeNanoseconds
        var renderedPageCount = 0
        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let image = page.thumbnail(of: CGSize(width: 128, height: 176), for: .mediaBox)
                if image.tiffRepresentation != nil { renderedPageCount += 1 }
            }
        }
        let allPagesMilliseconds = elapsedMilliseconds(since: allPagesStart)

        // Benchmark a fresh copy in the system temporary directory. The input is
        // never used as a write target, and this uniquely named file is removed.
        let saveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperplane-save-probe-\(UUID().uuidString).pdf")
        let saveStart = DispatchTime.now().uptimeNanoseconds
        guard document.write(to: saveURL) else {
            fail("PDFKit could not write the temporary save benchmark.")
        }
        let saveMilliseconds = elapsedMilliseconds(since: saveStart)
        defer { try? FileManager.default.removeItem(at: saveURL) }
        guard let savedDocument = PDFDocument(url: saveURL), savedDocument.pageCount == document.pageCount else {
            fail("Temporary save did not reopen with the original page count.")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)

        print("PDFKit performance probe (thumbnail render; not a UI frame-rate test)")
        print("file=\(inputURL.lastPathComponent)")
        print("pages=\(document.pageCount)")
        print("document_open_ms=\(openMilliseconds)")
        print("first_page_raster_ms=\(firstPageMilliseconds)")
        print("all_page_thumbnails_ms=\(allPagesMilliseconds)")
        print("temporary_save_ms=\(saveMilliseconds)")
        print("temporary_save_reopen_pages=\(savedDocument.pageCount)")
        print("rendered_pages=\(renderedPageCount)")
        print("peak_rss_mb=\(Double(usage.ru_maxrss) / 1_048_576.0)")
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func fail(_ message: String) -> Never {
        fputs("ERROR: \(message)\n", stderr)
        exit(1)
    }
}
