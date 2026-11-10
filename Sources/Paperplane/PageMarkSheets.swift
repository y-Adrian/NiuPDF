import AppKit
import PaperplaneCore
import SwiftUI

/// A color picker bound to a stored sRGB color.
private func colorBinding(_ color: Binding<MarkColor>) -> Binding<Color> {
    Binding(
        get: { Color(.sRGB, red: color.wrappedValue.red, green: color.wrappedValue.green, blue: color.wrappedValue.blue) },
        set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            color.wrappedValue = MarkColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        }
    )
}

/// The current page with the marks being set up.
private struct MarkPreview: View {
    let image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .border(Color.secondary.opacity(0.4), width: 1)
                } else {
                    Color.clear
                }
            }
            .frame(width: 220, height: 290)
            Text(L("Current page"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Text or an image over the pages, turned and faded, once or repeated.
struct WatermarkSheet: View {
    @EnvironmentObject private var library: ReaderLibrary
    @State private var settings = WatermarkSettings()
    @State private var image: CGImage?
    @State private var hasWatermark = false
    @State private var preview: NSImage?
    @State private var problem: String?

    private var canApply: Bool {
        settings.usesImage ? image != nil : !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Watermark"))
                    .font(.headline)
                Picker("", selection: $settings.usesImage) {
                    Text(L("Text")).tag(false)
                    Text(L("Image")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    if settings.usesImage {
                        GridRow {
                            Text(L("Image:")).gridColumnAlignment(.trailing)
                            HStack {
                                Button(L("Choose Image…")) { chooseImage() }
                                if image == nil {
                                    Text(L("No image chosen"))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        GridRow {
                            Text(L("Size:"))
                            slider($settings.imageScale, in: 0.1...1, step: 0.05, label: "\(Int((settings.imageScale * 100).rounded()))%")
                        }
                    } else {
                        GridRow {
                            Text(L("Text:")).gridColumnAlignment(.trailing)
                            TextField("", text: $settings.text)
                        }
                        GridRow {
                            Text(L("Font size:"))
                            HStack {
                                TextField("", value: $settings.fontSize, format: .number.precision(.fractionLength(0)))
                                    .frame(width: 48)
                                    .multilineTextAlignment(.trailing)
                                Stepper("", value: $settings.fontSize, in: 8...200, step: 4)
                                    .labelsHidden()
                            }
                        }
                        GridRow {
                            Text(L("Color:"))
                            ColorPicker("", selection: colorBinding($settings.color), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                    GridRow {
                        Text(L("Opacity:"))
                        slider($settings.opacity, in: 0.05...1, step: 0.05, label: "\(Int((settings.opacity * 100).rounded()))%")
                    }
                    GridRow {
                        Text(L("Angle:"))
                        slider($settings.angle, in: -90...90, step: 15, label: "\(Int(settings.angle))°")
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Toggle(L("Repeat across the page"), isOn: $settings.tiled)
                    }
                    GridRow {
                        Text(L("Pages:"))
                        TextField(L("All pages, or for example 1-3, 5"), text: $settings.pages)
                    }
                }
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack {
                    if hasWatermark {
                        Button(L("Remove Watermark")) {
                            library.removePageMarks(.watermark)
                            library.pageSheet = nil
                        }
                    }
                    Spacer()
                    Button(L("Cancel"), role: .cancel) { library.pageSheet = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(hasWatermark ? L("Change") : L("Add")) { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canApply)
                }
            }
            .frame(width: 340)
            MarkPreview(image: preview)
        }
        .padding(20)
        .onAppear {
            if let current = library.currentWatermark() {
                settings = current.settings
                image = current.image
                hasWatermark = true
            } else {
                settings.text = L("CONFIDENTIAL")
            }
            updatePreview()
        }
        .onChange(of: settings) { _ in
            problem = nil
            updatePreview()
        }
    }

    private func slider(_ value: Binding<Double>, in range: ClosedRange<Double>, step: Double, label: String) -> some View {
        HStack {
            Slider(value: value, in: range, step: step)
            Text(label)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = L("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let picture = NSImage(contentsOf: url), let cgImage = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            problem = L("“%@” couldn’t be read as an image.", url.lastPathComponent)
            return
        }
        image = cgImage
        updatePreview()
    }

    private func updatePreview() {
        guard let page = library.document?.page(at: library.currentPageIndex) else { return }
        let marks = canApply ? [PageMark.watermark(settings, image: image, on: page)] : []
        preview = library.previewImage(of: page, replacing: .watermark, with: marks, width: 220)
    }

    private func apply() {
        do {
            try library.applyWatermark(settings, image: image)
            library.pageSheet = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Texts at the top and bottom of pages, page numbers among them.
struct HeaderFooterSheet: View {
    @EnvironmentObject private var library: ReaderLibrary
    @State private var settings = HeaderFooterSettings()
    @State private var hasHeaderFooter = false
    @State private var preview: NSImage?
    @State private var problem: String?
    @FocusState private var focused: MarkPosition?
    /// Where Insert and page number formats put their text.
    @State private var target: MarkPosition = .bottomCenter

    private var marginMillimetres: Binding<Double> {
        Binding(
            get: { (settings.margin / Double(pointsPerMillimeter) * 10).rounded() / 10 },
            set: { settings.margin = max(0, $0) * Double(pointsPerMillimeter) }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Header & Footer"))
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text(L("Left")).font(.caption).foregroundStyle(.secondary)
                        Text(L("Center")).font(.caption).foregroundStyle(.secondary)
                        Text(L("Right")).font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text(L("Header:")).gridColumnAlignment(.trailing)
                        field(.topLeft)
                        field(.topCenter)
                        field(.topRight)
                    }
                    GridRow {
                        Text(L("Footer:"))
                        field(.bottomLeft)
                        field(.bottomCenter)
                        field(.bottomRight)
                    }
                }
                HStack {
                    Menu(L("Insert")) {
                        Button(L("Page Number")) { insert(HeaderFooterSettings.pageToken) }
                        Button(L("Page Count")) { insert(HeaderFooterSettings.pageCountToken) }
                        Button(L("Date")) { insert(HeaderFooterSettings.dateToken) }
                        Button(L("File Name")) { insert(HeaderFooterSettings.fileToken) }
                    }
                    .fixedSize()
                    Menu(L("Page Number Format")) {
                        Button("1") { setText("{page}") }
                        Button("1 / N") { setText("{page} / {pages}") }
                        Button(L("Page 1 of N")) { setText(L("Page {page} of {pages}")) }
                        Button("- 1 -") { setText("- {page} -") }
                    }
                    .fixedSize()
                }
                Text(L("Insert and formats go into the field you edited last. {page} is the page number, {pages} the last page number."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Text(L("Font size:")).gridColumnAlignment(.trailing)
                        HStack {
                            TextField("", value: $settings.fontSize, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 48)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $settings.fontSize, in: 5...72)
                                .labelsHidden()
                        }
                    }
                    GridRow {
                        Text(L("Color:"))
                        ColorPicker("", selection: colorBinding($settings.color), supportsOpacity: false)
                            .labelsHidden()
                    }
                    GridRow {
                        Text(L("Margin:"))
                        HStack {
                            TextField("", value: marginMillimetres, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 48)
                                .multilineTextAlignment(.trailing)
                            Text(L("mm from the edge"))
                        }
                    }
                    GridRow {
                        Text(L("First number:"))
                        HStack {
                            TextField("", value: $settings.firstNumber, format: .number)
                                .frame(width: 48)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $settings.firstNumber, in: 0...99_999)
                                .labelsHidden()
                        }
                    }
                    GridRow {
                        Text(L("Pages:"))
                        TextField(L("All pages, or for example 1-3, 5"), text: $settings.pages)
                    }
                }
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack {
                    if hasHeaderFooter {
                        Button(L("Remove Header & Footer")) {
                            library.removePageMarks(.headerFooter)
                            library.pageSheet = nil
                        }
                    }
                    Spacer()
                    Button(L("Cancel"), role: .cancel) { library.pageSheet = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(hasHeaderFooter ? L("Change") : L("Add")) { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(settings.isEmpty)
                }
            }
            .frame(width: 420)
            MarkPreview(image: preview)
        }
        .padding(20)
        .onAppear {
            if let current = library.currentHeaderFooter() {
                settings = current
                hasHeaderFooter = true
            } else {
                settings.texts[.bottomCenter] = HeaderFooterSettings.pageToken
            }
            updatePreview()
        }
        .onChange(of: settings) { _ in
            problem = nil
            updatePreview()
        }
        .onChange(of: focused) { value in
            if let value { target = value }
        }
    }

    private func field(_ position: MarkPosition) -> some View {
        TextField("", text: Binding(
            get: { settings.texts[position] ?? "" },
            set: { settings.texts[position] = $0 }
        ))
        .focused($focused, equals: position)
        .frame(width: 104)
    }

    private func insert(_ token: String) {
        settings.texts[target, default: ""] += token
    }

    private func setText(_ text: String) {
        settings.texts[target] = text
    }

    private func updatePreview() {
        guard let page = library.document?.page(at: library.currentPageIndex) else { return }
        var marks: [PageMark] = []
        // The current page as numbered, when it is one of the pages.
        if let indexes = try? library.pageIndexes(settings.pages),
           let ordinal = indexes.firstIndex(of: library.currentPageIndex) {
            marks = ReaderLibrary.headerMarks(library.datedHeaderFooter(settings), ordinal: ordinal, count: indexes.count, on: page)
        }
        preview = library.previewImage(of: page, replacing: .headerFooter, with: marks, width: 220)
    }

    private func apply() {
        do {
            try library.applyHeaderFooter(settings)
            library.pageSheet = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
