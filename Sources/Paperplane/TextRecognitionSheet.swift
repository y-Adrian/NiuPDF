import AppKit
import PaperplaneCore
import PDFKit
import SwiftUI

/// Recognizing the text of scanned pages, so they can be searched, selected
/// and copied. Vision reads a copy of the document in the background; when
/// all pages are read, each one is replaced by the same page with the text
/// as an invisible layer, in one step that undoes.
extension ReaderLibrary {
    /// Reads the pages and replaces them; `skipping` leaves out pages that
    /// already have text. Reports through `recognitionProgress`.
    func recognizeText(on indexes: [Int], skippingPagesWithText skipping: Bool) {
        guard let document, canChangePages, recognitionTask == nil else { return }
        commitPendingEdits?()
        // Pages are judged and read on a copy written from the document: in a
        // PDFView, PDFKit reads pictures of text itself and puts that text into
        // the pages it shows (`string`, even `pageRef`), but not into the file.
        guard let snapshot = exportSnapshot(of: document) else {
            errorMessage = DocumentExportError.unableToWrite.localizedDescription
            return
        }
        let wanted = indexes.filter { $0 >= 0 && $0 < document.pageCount }
        let originals = UncheckedSendable(value: wanted.compactMap { document.page(at: $0) })
        let total = wanted.count
        recognitionProgress = (0, total)
        let report: @MainActor @Sendable (Int) -> Void = { [weak self] done in self?.recognitionProgress = (done, total) }
        let finish: @MainActor @Sendable (UncheckedSendable<[(Int, PDFPage)]>?, String?) -> Void = { [weak self] made, failure in
            self?.finishRecognition(originals: originals.value, made: made?.value, failure: failure)
        }
        recognitionTask = Task.detached(priority: .userInitiated) {
            var made: [(Int, PDFPage)] = []
            for (position, index) in wanted.enumerated() {
                if Task.isCancelled { await finish(nil, nil); return }
                guard let page = snapshot.value.page(at: index) else { continue }
                if skipping, TextRecognizer.hasText(page) {
                    await report(position + 1)
                    continue
                }
                do {
                    let lines = try TextRecognizer.recognize(page)
                    guard let searchable = TextRecognizer.searchablePage(from: page, lines: lines) else {
                        await finish(nil, DocumentExportError.unableToWrite.localizedDescription)
                        return
                    }
                    made.append((position, searchable))
                } catch {
                    await finish(nil, error.localizedDescription)
                    return
                }
                await report(position + 1)
            }
            await finish(UncheckedSendable(value: made), nil)
        }
    }

    func cancelRecognition() {
        recognitionTask?.cancel()
    }

    /// `made` pairs a position in `originals` with its new page.
    private func finishRecognition(originals: [PDFPage], made: [(Int, PDFPage)]?, failure: String?) {
        recognitionTask = nil
        recognitionProgress = nil
        if let failure { errorMessage = failure }
        guard let made else { return }
        guard !made.isEmpty else {
            errorMessage = L("The chosen pages already have text.")
            return
        }
        replacePages(made.map { (old: originals[$0.0], new: $0.1) }, actionName: L("Recognize Text"))
        pageSheet = nil
        let found = made.filter { TextRecognizer.hasText($0.1) }.count
        showExportStatus(found == made.count
            ? L("Recognized text on %ld pages.", made.count)
            : L("Recognized text on %ld of %ld pages.", found, made.count))
    }
}

/// Which pages to read, and progress while they are read.
struct TextRecognitionSheet: View {
    @EnvironmentObject private var library: ReaderLibrary
    @State private var range = ""
    @State private var usesRange = false
    @State private var skipsPagesWithText = true
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Recognize Text"))
                .font(.headline)
            Text(L("Makes scanned pages searchable: the text found is added to the page as an invisible layer, and the page looks the same."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let progress = library.recognitionProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text(L("Reading page %ld of %ld…", min(progress.done + 1, progress.total), progress.total))
                        .font(.callout)
                        .monospacedDigit()
                }
                HStack {
                    Spacer()
                    Button(L("Stop")) { library.cancelRecognition() }
                        .keyboardShortcut(.cancelAction)
                }
            } else {
                Picker(L("Pages:"), selection: $usesRange) {
                    Text(L("Current Page")).tag(false)
                    HStack {
                        Text(L("Pages:"))
                        TextField(L("All pages, or for example 1-3, 5"), text: $range)
                            .frame(width: 180)
                            .disabled(!usesRange)
                    }
                    .tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Toggle(L("Skip pages that already have text"), isOn: $skipsPagesWithText)
                Text(L("Chinese, English, Japanese and Korean are recognized. Reading takes about a second a page."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(L("Cancel"), role: .cancel) { library.pageSheet = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(L("Recognize")) { start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { usesRange = library.pageCount > 1 }
        .onChange(of: library.errorMessage) { message in
            // A failure shows in the sheet, not behind it.
            if let message, library.pageSheet == .recognizeText {
                problem = message
                library.errorMessage = nil
            }
        }
    }

    private func start() {
        problem = nil
        let indexes: [Int]
        if usesRange {
            do {
                indexes = try library.pageIndexes(range)
            } catch {
                problem = error.localizedDescription
                return
            }
        } else {
            indexes = [library.currentPageIndex]
        }
        library.recognizeText(on: indexes, skippingPagesWithText: skipsPagesWithText)
    }
}
