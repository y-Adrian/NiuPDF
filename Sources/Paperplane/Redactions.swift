import AppKit
import PaperplaneCore
import PDFKit
import SwiftUI

/// Redacting in two steps, as in other PDF editors: areas are marked first
/// (the Redact tool, or selected text), and can be moved, resized or removed;
/// applying them replaces each marked page by a picture of it with the areas
/// black (`Redactor`), which undoes as one step until the file is saved.
extension ReaderLibrary {
    /// Marks a square annotation as an area to redact.
    static let redactionKey = PDFAnnotationKey(rawValue: "/PaperplaneRedaction")

    static func isRedactionMark(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Square" && annotation.value(forAnnotationKey: redactionKey) != nil
    }

    /// Every redaction mark, with its page.
    var redactionMarks: [(page: PDFPage, mark: PDFAnnotation)] {
        guard let document else { return [] }
        return (0..<document.pageCount).compactMap { document.page(at: $0) }.flatMap { page in
            page.annotations.filter(Self.isRedactionMark).map { (page, $0) }
        }
    }

    /// Adds marks over page areas: red outline, dark translucent fill.
    func addRedactionMarks(_ areas: [(PDFPage, CGRect)]) {
        guard canAnnotate, !areas.isEmpty else { return }
        var pages: [PDFPage] = []
        for (page, _) in areas where !pages.contains(where: { $0 === page }) { pages.append(page) }
        recordAnnotationEdit(L("Mark for Redaction"), pages: pages) {
            for (page, area) in areas {
                let mark = PDFAnnotation(bounds: area, forType: .square, withProperties: nil)
                mark.setValue("1", forAnnotationKey: Self.redactionKey)
                mark.color = .systemRed
                mark.interiorColor = NSColor.black.withAlphaComponent(0.3)
                mark.border = {
                    let border = PDFBorder()
                    border.lineWidth = 1.5
                    return border
                }()
                handOverToOverlay(mark)
                page.addAnnotation(mark)
            }
        }
    }

    /// Annotate ▸ Mark Selection for Redaction: one mark over each line.
    func markSelectionForRedaction() {
        guard canAnnotate else { return }
        guard let selection = pdfView?.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = L("Select the text to redact first.")
            return
        }
        let areas = selection.selectionsByLine().flatMap { line in
            line.pages.map { page in (page, line.bounds(for: page).insetBy(dx: -1, dy: -1)) }
        }.filter { !$0.1.isEmpty }
        addRedactionMarks(areas)
        pdfView?.clearSelection()
    }

    /// Annotate ▸ Apply Redactions: asks, then makes the marked pages again in
    /// the background with `recognitionProgress`, as text recognition does.
    func applyRedactions() {
        guard let document, canChangePages, recognitionTask == nil else { return }
        commitPendingEdits?()
        let marks = redactionMarks
        guard !marks.isEmpty else {
            errorMessage = L("Mark the areas to redact first, with the Redact tool or by selecting text.")
            return
        }
        var areas: [Int: [CGRect]] = [:]
        for (page, mark) in marks { areas[document.index(for: page), default: []].append(mark.bounds) }

        let alert = NSAlert()
        alert.messageText = L("Apply %ld redactions on %ld pages?", marks.count, areas.count)
        alert.informativeText = L("What is under the marked areas is removed for good once the document is saved. The pages become images; annotations over the areas are removed.")
        alert.addButton(withTitle: L("Apply Redactions"))
        alert.addButton(withTitle: L("Cancel"))
        let recognize = NSButton(checkboxWithTitle: L("Recognize the remaining text, so the pages stay searchable"), target: nil, action: nil)
        recognize.state = .on
        alert.accessoryView = recognize
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startRedaction(areas: areas, recognizingText: recognize.state == .on)
    }

    func startRedaction(areas: [Int: [CGRect]], recognizingText: Bool) {
        guard let document, recognitionTask == nil, let snapshot = exportSnapshot(of: document) else { return }
        let indexes = areas.keys.sorted()
        let originals = UncheckedSendable(value: indexes.compactMap { document.page(at: $0) })
        let total = indexes.count
        recognitionProgress = (0, total)
        progressTitle = L("Applying Redactions")
        pageSheet = .progress
        let report: @MainActor @Sendable (Int) -> Void = { [weak self] done in self?.recognitionProgress = (done, total) }
        let finish: @MainActor @Sendable (UncheckedSendable<[PDFPage]>?, String?) -> Void = { [weak self] made, failure in
            guard let self else { return }
            self.recognitionTask = nil
            self.recognitionProgress = nil
            self.pageSheet = nil
            if let failure { self.errorMessage = failure }
            guard let made = made?.value, made.count == originals.value.count else { return }
            // Marks and annotations over the areas stay on the old pages: gone
            // with them, back with them on undo.
            var leaving = Set<ObjectIdentifier>()
            for page in originals.value {
                let pageAreas = areas[document.index(for: page)] ?? []
                for annotation in page.annotations
                where Self.isRedactionMark(annotation) || pageAreas.contains(where: { $0.intersects(annotation.bounds) }) {
                    leaving.insert(ObjectIdentifier(annotation))
                }
            }
            self.replacePages(zip(originals.value, made).map { (old: $0, new: $1) }, actionName: L("Apply Redactions"), leaving: leaving)
            self.showExportStatus(L("Redacted %ld pages. Save to make it permanent.", made.count))
        }
        recognitionTask = Task.detached(priority: .userInitiated) {
            var made: [PDFPage] = []
            for (done, index) in indexes.enumerated() {
                if Task.isCancelled { await finish(nil, nil); return }
                guard let page = snapshot.value.page(at: index) else { await finish(nil, nil); return }
                do {
                    made.append(try Redactor.redactedPage(from: page, areas: areas[index] ?? [], recognizingText: recognizingText))
                } catch {
                    await finish(nil, error.localizedDescription)
                    return
                }
                await report(done + 1)
            }
            await finish(UncheckedSendable(value: made), nil)
        }
    }
}

/// Progress of a long page operation, with Stop.
struct PageProgressSheet: View {
    @EnvironmentObject private var library: ReaderLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(library.progressTitle)
                .font(.headline)
            let progress = library.recognitionProgress ?? (0, 1)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text(L("Page %ld of %ld…", min(progress.done + 1, progress.total), progress.total))
                .font(.callout)
                .monospacedDigit()
            HStack {
                Spacer()
                Button(L("Stop")) { library.cancelRecognition() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
