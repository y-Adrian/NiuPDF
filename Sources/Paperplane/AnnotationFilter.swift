import PDFKit
import SwiftUI

/// The kinds the annotation list filters by. Shapes are one kind, since the
/// toolbar groups them; markup kinds come from `MarkupEngine.tool(of:)`.
enum AnnotationListKind: String, CaseIterable, Identifiable {
    case highlight
    case underline
    case squiggly
    case strikeOut
    case note
    case textBox
    case drawing
    case shape
    case stamp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highlight: L("Highlight")
        case .underline: L("Underline")
        case .squiggly: L("Squiggly")
        case .strikeOut: L("Strikethrough")
        case .note: L("Note")
        case .textBox: L("Text Box")
        case .drawing: L("Drawing")
        case .shape: L("Shapes")
        case .stamp: L("Stamp")
        }
    }

    var symbol: String {
        switch self {
        case .highlight: AnnotationTool.highlight.symbol
        case .underline: AnnotationTool.underline.symbol
        case .squiggly: AnnotationTool.squiggly.symbol
        case .strikeOut: AnnotationTool.strikeOut.symbol
        case .note: AnnotationTool.note.symbol
        case .textBox: AnnotationTool.textBox.symbol
        case .drawing: AnnotationTool.ink.symbol
        case .shape: "square.on.circle"
        case .stamp: "seal"
        }
    }

    /// The listed kind of `annotation`; nil for links, widgets, popups and others the list skips.
    static func of(_ annotation: PDFAnnotation) -> AnnotationListKind? {
        if let tool = MarkupEngine.tool(of: annotation) {
            switch tool {
            case .highlight: return .highlight
            case .underline: return .underline
            case .squiggly: return .squiggly
            case .strikeOut: return .strikeOut
            default: return nil
            }
        }
        switch annotation.type {
        case "Squiggly": return .squiggly
        case "Text": return .note
        case "FreeText": return .textBox
        case "Ink": return .drawing
        case "Square", "Circle", "Line": return .shape
        case "Stamp": return .stamp
        default: return nil
        }
    }
}

/// The annotation list's filter, kept per window. Within a dimension any chosen
/// value matches; the dimensions combine, and an empty one matches everything.
struct AnnotationListFilter: Equatable {
    var kinds: Set<AnnotationListKind> = []
    /// Color hex values, as in `AnnotationListItem.color`.
    var colors: Set<String> = []
    /// Author names; the empty string stands for annotations without one.
    var authors: Set<String> = []

    var isActive: Bool { !kinds.isEmpty || !colors.isEmpty || !authors.isEmpty }

    func matches(_ item: AnnotationListItem) -> Bool {
        (kinds.isEmpty || kinds.contains(item.listKind))
            && (colors.isEmpty || colors.contains(item.color.hex))
            && (authors.isEmpty || authors.contains(item.author))
    }
}

extension MarkupColor {
    /// The closest of `palette` when `color` is practically the same, so a
    /// color read back from a file, a step or so off, still groups with the
    /// one it was saved as; otherwise `color` itself, titled by its hex value.
    init(nearest color: NSColor, among palette: [MarkupColor]) {
        let components = Self.components(of: color)
        if let match = palette.min(by: { Self.distance($0, components) < Self.distance($1, components) }),
           Self.distance(match, components) < 0.05 {
            self = match
        } else {
            let hex = components.map { String(format: "%02X", lround(Double($0) * 255)) }.joined()
            self.init(hex: hex, title: "#" + hex)
        }
    }

    /// RGB components as stored. Palette colors are calibrated and PDFKit reads
    /// them back as device RGB with the same numbers, so converting between the
    /// two spaces would set them apart. Colors without RGB components, such as
    /// patterns, count as black.
    private static func components(of color: NSColor) -> [CGFloat] {
        let rgb = color.type == .componentBased && color.colorSpace.colorSpaceModel == .rgb ? color : color.usingColorSpace(.deviceRGB)
        guard let rgb else { return [0, 0, 0] }
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
    }

    private static func distance(_ candidate: MarkupColor, _ components: [CGFloat]) -> CGFloat {
        zip(Self.components(of: candidate.nsColor), components).reduce(0) { $0 + abs($1.0 - $1.1) }
    }
}

/// The filter button's popover: kinds, colors and authors found in the
/// document, each with how many annotations have it.
struct AnnotationFilterPopover: View {
    @EnvironmentObject private var library: ReaderLibrary
    let items: [AnnotationListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section(L("Type")) {
                ForEach(kinds, id: \.self) { kind in
                    toggle(isOn: binding(\.kinds, kind), count: items.filter { $0.listKind == kind }.count) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
            section(L("Color")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 22), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(colors) { color in
                        colorSwatch(color)
                    }
                }
            }
            if authors.count > 1 || authors.first.map({ !$0.isEmpty }) == true {
                section(L("Author")) {
                    ForEach(authors, id: \.self) { author in
                        toggle(isOn: binding(\.authors, author), count: items.filter { $0.author == author }.count) {
                            Text(author.isEmpty ? L("No Author") : author)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            Divider()
            Button(L("Clear Filters")) { library.annotationListFilter = AnnotationListFilter() }
                .disabled(!library.annotationListFilter.isActive)
        }
        .padding(14)
        .frame(width: 230)
    }

    /// Present kinds, plus chosen ones whose annotations are gone, so they can be turned off.
    private var kinds: [AnnotationListKind] {
        let present = Set(items.map(\.listKind)).union(library.annotationListFilter.kinds)
        return AnnotationListKind.allCases.filter(present.contains)
    }

    /// In the order they first appear in the document.
    private var colors: [MarkupColor] {
        var seen = Set<String>()
        var colors = items.map(\.color).filter { seen.insert($0.hex).inserted }
        colors += library.annotationListFilter.colors.subtracting(seen).sorted().map { MarkupColor(hex: $0, title: "#" + $0) }
        return colors
    }

    /// Named authors alphabetically, then annotations without one.
    private var authors: [String] {
        let all = Set(items.map(\.author)).union(library.annotationListFilter.authors)
        return all.sorted { lhs, rhs in
            lhs.isEmpty != rhs.isEmpty ? !lhs.isEmpty : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func binding<Value: Hashable>(_ keyPath: WritableKeyPath<AnnotationListFilter, Set<Value>>, _ value: Value) -> Binding<Bool> {
        Binding(
            get: { library.annotationListFilter[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn {
                    library.annotationListFilter[keyPath: keyPath].insert(value)
                } else {
                    library.annotationListFilter[keyPath: keyPath].remove(value)
                }
            }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func toggle<Label: View>(isOn: Binding<Bool>, count: Int, @ViewBuilder label: () -> Label) -> some View {
        HStack {
            Toggle(isOn: isOn, label: label)
                .toggleStyle(.checkbox)
            Spacer(minLength: 4)
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func colorSwatch(_ color: MarkupColor) -> some View {
        let isOn = binding(\.colors, color.hex)
        let count = items.filter { $0.color.hex == color.hex }.count
        return Button { isOn.wrappedValue.toggle() } label: {
            Circle()
                .fill(Color(nsColor: color.nsColor))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .padding(2)
                .overlay(Circle().strokeBorder(isOn.wrappedValue ? Color.accentColor : .clear, lineWidth: 2))
                .overlay(alignment: .center) {
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(color.prefersDarkCheckmark ? Color.black : Color.white)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(color.title) (\(count))")
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}

private extension MarkupColor {
    var prefersDarkCheckmark: Bool {
        guard let rgb = nsColor.usingColorSpace(.deviceRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.6
    }
}
