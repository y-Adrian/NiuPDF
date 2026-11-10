import AppKit
import PaperplaneCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// What a batch does to each file.
enum BatchAction: String, CaseIterable, Identifiable {
    case reduceSize
    case recognizeText
    case pageNumbers
    case watermark
    case exportText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reduceSize: L("Reduce File Size")
        case .recognizeText: L("Recognize Text")
        case .pageNumbers: L("Add Page Numbers")
        case .watermark: L("Add Watermark")
        case .exportText: L("Export Text")
        }
    }

    /// Added to each file's name, so originals are never replaced.
    func outputName(for source: URL, textFormat: TextExportFormat) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        switch self {
        case .reduceSize: return L("%@ (Smaller)", base) + ".pdf"
        case .recognizeText: return L("%@ (Searchable)", base) + ".pdf"
        case .pageNumbers: return L("%@ (Numbered)", base) + ".pdf"
        case .watermark: return L("%@ (Watermarked)", base) + ".pdf"
        case .exportText: return base + "." + textFormat.fileExtension
        }
    }
}

/// One file of the batch and how it went.
struct BatchFile: Identifiable {
    enum Status: Equatable {
        case waiting
        case working
        case done(URL)
        case skipped(String)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var status: Status = .waiting
}

/// The settings a run uses, copied for the background task.
struct BatchSettings: Sendable {
    var action: BatchAction
    var textFormat: TextExportFormat
    var pageNumberFormat: String
    var watermarkText: String
}

/// Files and settings of the batch window, shared so the File menu can open it.
@MainActor
final class BatchModel: ObservableObject {
    static let shared = BatchModel()

    @Published var files: [BatchFile] = []
    @Published var action: BatchAction = .reduceSize
    @Published var textFormat: TextExportFormat = .plainText
    @Published var pageNumberFormat = HeaderFooterSettings.pageToken + " / " + HeaderFooterSettings.pageCountToken
    @Published var watermarkText = L("CONFIDENTIAL")
    @Published var outputFolder: URL?
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?

    var canRun: Bool {
        !isRunning && !files.isEmpty && outputFolder != nil
            && !(action == .watermark && watermarkText.trimmingCharacters(in: .whitespaces).isEmpty)
            && !(action == .pageNumbers && pageNumberFormat.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func add(_ urls: [URL]) {
        var known = Set(files.map { $0.url.standardizedFileURL })
        for url in urls where url.pathExtension.lowercased() == "pdf" && known.insert(url.standardizedFileURL).inserted {
            files.append(BatchFile(url: url))
        }
    }

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Choose")
        panel.message = L("New files are saved in this folder. The originals are not changed.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url
    }

    func remove(_ ids: Set<BatchFile.ID>) {
        guard !isRunning else { return }
        files.removeAll { ids.contains($0.id) }
    }

    /// Processes the files one after another in the background.
    func run() {
        guard canRun, let folder = outputFolder else { return }
        for index in files.indices { files[index].status = .waiting }
        let settings = BatchSettings(action: action, textFormat: textFormat, pageNumberFormat: pageNumberFormat, watermarkText: watermarkText)
        let jobs = files.map { ($0.id, $0.url) }
        isRunning = true
        let update: @MainActor @Sendable (UUID, BatchFile.Status) -> Void = { [weak self] id, status in
            guard let self, let index = self.files.firstIndex(where: { $0.id == id }) else { return }
            self.files[index].status = status
        }
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            self?.isRunning = false
            self?.task = nil
        }
        task = Task.detached(priority: .userInitiated) {
            let didStart = folder.startAccessingSecurityScopedResource()
            defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
            for (id, url) in jobs {
                if Task.isCancelled { break }
                await update(id, .working)
                await update(id, BatchProcessor.process(url, settings: settings, into: folder))
            }
            await finish()
        }
    }

    func stop() {
        task?.cancel()
    }
}

/// The work on one file, away from the main thread: each file is its own
/// document, read from disk and written to a new file.
enum BatchProcessor {
    static func process(_ url: URL, settings: BatchSettings, into folder: URL) -> BatchFile.Status {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return .failed(L("“%@” couldn’t be read as a PDF.", url.lastPathComponent))
        }
        // Passwords would have to be asked file by file; restrictions would
        // be lost or drop the changes when written. Files without encryption
        // have no restrictions.
        guard !document.isEncrypted else { return .skipped(L("Encrypted files are skipped.")) }
        let output = DocumentConverter.unusedURL(for: settings.action.outputName(for: url, textFormat: settings.textFormat), in: folder)
        do {
            switch settings.action {
            case .reduceSize:
                try DocumentExporter.writeCopy(of: document, to: output, flattenAnnotations: false, reducesFileSize: true)
                // Files with few images can come out larger.
                if let before = fileSize(url), let after = fileSize(output), after >= before {
                    try? FileManager.default.removeItem(at: output)
                    return .skipped(L("Reducing would not make this file smaller."))
                }
            case .recognizeText:
                switch try recognizeText(in: document) {
                case .changed: break
                case .allHaveText: return .skipped(L("All pages already have text."))
                case .nothingFound: return .skipped(L("No text was found on the pages without text."))
                }
                try write(document, to: output)
            case .pageNumbers:
                var header = HeaderFooterSettings()
                header.texts[.bottomCenter] = settings.pageNumberFormat
                header.date = Date().formatted(date: .numeric, time: .omitted)
                header.fileName = url.deletingPathExtension().lastPathComponent
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    removeMarks(.headerFooter, from: page)
                    let text = header.text(at: .bottomCenter, ordinal: index, count: document.pageCount)
                    page.addAnnotation(PageMark.header(header, at: .bottomCenter, text: text, on: page))
                }
                try write(document, to: output)
            case .watermark:
                var watermark = WatermarkSettings()
                watermark.text = settings.watermarkText
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    removeMarks(.watermark, from: page)
                    page.addAnnotation(PageMark.watermark(watermark, image: nil, on: page))
                }
                try write(document, to: output)
            case .exportText:
                try DocumentConverter.textData(of: document, format: settings.textFormat).write(to: output)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        return .done(output)
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private static func write(_ document: PDFDocument, to url: URL) throws {
        guard document.write(to: url) else { throw DocumentExportError.unableToWrite }
    }

    private static func removeMarks(_ kind: PageMark.Kind, from page: PDFPage) {
        for annotation in page.annotations where PageMark.kind(of: annotation) == kind {
            page.removeAnnotation(annotation)
        }
    }

    private enum Recognition {
        case changed
        case allHaveText
        case nothingFound
    }

    /// Replaces pages without text by pages with a text layer, keeping their
    /// annotations.
    private static func recognizeText(in document: PDFDocument) throws -> Recognition {
        var result = Recognition.allHaveText
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), !TextRecognizer.hasText(page) else { continue }
            if result == .allHaveText { result = .nothingFound }
            let lines = try TextRecognizer.recognize(page)
            guard !lines.isEmpty, let made = TextRecognizer.searchablePage(from: page, lines: lines) else { continue }
            for annotation in page.annotations {
                page.removeAnnotation(annotation)
                made.addAnnotation(annotation)
            }
            document.removePage(at: index)
            document.insert(made, at: index)
            result = .changed
        }
        return result
    }
}

/// File ▸ Batch Process: one action on many files, each written as a new
/// file in a chosen folder.
struct BatchWindow: View {
    @ObservedObject private var model = BatchModel.shared
    @State private var selection = Set<BatchFile.ID>()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                fileList
                    .frame(minWidth: 380)
                Divider()
                settings
                    .frame(width: 320)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 440)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { model.add([url]) } }
                }
            }
            return true
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Files"))
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if model.files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(L("Drag PDFs here, or add them from your files."))
                        .foregroundStyle(.secondary)
                    Button(L("Add Files…")) { model.presentAddPanel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .padding(12)
                }
            } else {
                List(selection: $selection) {
                    ForEach(model.files) { file in
                        HStack {
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(.secondary)
                            Text(file.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(file.url.path)
                            Spacer()
                            status(of: file)
                        }
                    }
                }
                .onDeleteCommand { model.remove(selection) }
            }
            HStack(spacing: 4) {
                Button { model.presentAddPanel() } label: { Image(systemName: "plus") }
                    .help(L("Add Files…"))
                Button {
                    model.remove(selection)
                    selection = []
                } label: { Image(systemName: "minus") }
                    .help(L("Remove"))
                    .disabled(selection.isEmpty || model.isRunning)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .disabled(model.isRunning)
    }

    @ViewBuilder
    private func status(of file: BatchFile) -> some View {
        switch file.status {
        case .waiting:
            EmptyView()
        case .working:
            ProgressView().controlSize(.small)
        case let .done(url):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label(L("Done"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help(url.lastPathComponent)
        case let .skipped(reason):
            Label(L("Skipped"), systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .help(reason)
        case let .failed(reason):
            Label(L("Failed"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(reason)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Action"))
                .font(.headline)
            Picker("", selection: $model.action) {
                ForEach(BatchAction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Group {
                switch model.action {
                case .reduceSize:
                    Text(L("Recompresses and downsamples images, as Preview’s Reduce File Size does. Text and annotations are kept."))
                case .recognizeText:
                    Text(L("Adds an invisible text layer to pages without text, so scanned files can be searched."))
                case .pageNumbers:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Format at the bottom center; {page} is the page number, {pages} the last page number."))
                        TextField("", text: $model.pageNumberFormat)
                            .textFieldStyle(.roundedBorder)
                    }
                case .watermark:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Gray text across each page, turned 45°."))
                        TextField("", text: $model.watermarkText)
                            .textFieldStyle(.roundedBorder)
                    }
                case .exportText:
                    Picker(L("Format"), selection: $model.textFormat) {
                        Text(verbatim: "TXT").tag(TextExportFormat.plainText)
                        Text(verbatim: "RTF").tag(TextExportFormat.richText)
                        Text(verbatim: "Word").tag(TextExportFormat.word)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L("Save To"))
                .font(.headline)
            HStack {
                Text(model.outputFolder?.lastPathComponent ?? L("No folder chosen"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.outputFolder == nil ? .secondary : .primary)
                    .help(model.outputFolder?.path ?? "")
                Spacer()
                Button(L("Choose…")) { model.chooseOutputFolder() }
            }
            Text(L("Encrypted files are skipped. Existing files are not replaced."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .disabled(model.isRunning)
    }

    private var footer: some View {
        HStack {
            let done = model.files.filter { if case .done = $0.status { true } else { false } }.count
            Text(L("%ld files, %ld done", model.files.count, done))
                .foregroundStyle(.secondary)
            Spacer()
            if let folder = model.outputFolder, done > 0 {
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            if model.isRunning {
                Button(L("Stop")) { model.stop() }
            } else {
                Button(L("Start")) { model.run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
