import AppKit
import PaperplaneCore
import SwiftUI

/// Sheets for page tools that need settings.
enum PageSheet: String, Identifiable {
    case crop
    case split
    case watermark
    case headerFooter
    case recognizeText
    case progress

    var id: String { rawValue }
}

/// Which pages a page tool applies to.
enum PageScope: Hashable {
    case current
    case selected
    case all
}

extension ReaderLibrary {
    func indexes(for scope: PageScope) -> IndexSet {
        switch scope {
        case .current: IndexSet(integer: currentPageIndex)
        case .selected: targetPages
        case .all: IndexSet(integersIn: 0..<pageCount)
        }
    }
}

let pointsPerMillimeter: CGFloat = 72 / 25.4

/// Margins in millimetres, as shown on screen, for one page, the selected
/// pages or all of them; the white space around the content can be measured.
struct CropSheet: View {
    @EnvironmentObject private var library: ReaderLibrary
    @State private var top: Double = 0
    @State private var bottom: Double = 0
    @State private var left: Double = 0
    @State private var right: Double = 0
    @State private var scope: PageScope = .current
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Crop Pages"))
                .font(.headline)
            Text(L("Margins to remove, in millimetres, as the page is shown."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text(L("Top:")); field($top)
                    Text(L("Bottom:")); field($bottom)
                }
                GridRow {
                    Text(L("Left:")); field($left)
                    Text(L("Right:")); field($right)
                }
            }
            HStack {
                Button(L("Detect White Margins")) { detectMargins() }
                    .help(L("Measures the content of the current page."))
                Spacer()
            }
            Picker(L("Apply to:"), selection: $scope) {
                Text(L("Current Page")).tag(PageScope.current)
                if library.selectedPages.count > 1 {
                    Text(L("Selected Pages (%ld)", library.selectedPages.count)).tag(PageScope.selected)
                }
                Text(L("All Pages")).tag(PageScope.all)
            }
            .pickerStyle(.radioGroup)
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Button(L("Restore Original Size")) {
                    library.uncropPages(library.indexes(for: scope))
                    library.pageSheet = nil
                }
                Spacer()
                Button(L("Cancel"), role: .cancel) { library.pageSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L("Crop")) { crop() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            let current = library.cropMargins(ofPage: library.currentPageIndex)
            set(current)
            if library.selectedPages.count > 1 { scope = .selected }
        }
    }

    private func field(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
    }

    private func set(_ margins: PageMargins) {
        func millimetres(_ points: CGFloat) -> Double { (Double(points / pointsPerMillimeter) * 10).rounded() / 10 }
        top = millimetres(margins.top)
        bottom = millimetres(margins.bottom)
        left = millimetres(margins.left)
        right = millimetres(margins.right)
    }

    private func detectMargins() {
        guard let page = library.document?.page(at: library.currentPageIndex),
              let margins = PageCropper.contentMargins(of: page) else {
            problem = L("The page has no content to measure.")
            return
        }
        problem = nil
        set(margins)
    }

    private func crop() {
        let margins = PageMargins(
            top: max(0, CGFloat(top)) * pointsPerMillimeter,
            right: max(0, CGFloat(right)) * pointsPerMillimeter,
            bottom: max(0, CGFloat(bottom)) * pointsPerMillimeter,
            left: max(0, CGFloat(left)) * pointsPerMillimeter
        )
        if library.cropPages(library.indexes(for: scope), margins: margins) {
            library.pageSheet = nil
        } else {
            problem = L("The margins leave too little of a page.")
        }
    }
}

/// Splits the document into files of N pages, or one file per page range.
struct SplitSheet: View {
    private enum Mode: Hashable {
        case every
        case ranges
    }

    @EnvironmentObject private var library: ReaderLibrary
    @State private var mode: Mode = .every
    @State private var size = 1
    @State private var ranges = ""
    @State private var problem: String?

    private var groups: Result<[[Int]], Error> {
        switch mode {
        case .every:
            return .success(DocumentSplitter.groups(every: size, pageCount: library.pageCount))
        case .ranges:
            return Result { try DocumentSplitter.groups(from: ranges, pageCount: library.pageCount) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Split Document"))
                .font(.headline)
            Picker("", selection: $mode) {
                HStack {
                    Text(L("Every"))
                    TextField("", value: $size, format: .number)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                        .disabled(mode != .every)
                    Stepper("", value: $size, in: 1...max(1, library.pageCount))
                        .labelsHidden()
                        .disabled(mode != .every)
                    Text(L("pages"))
                }
                .tag(Mode.every)
                HStack {
                    Text(L("Page ranges:"))
                    TextField(L("for example 1-3, 4-8, 9-"), text: $ranges)
                        .frame(width: 180)
                        .disabled(mode != .ranges)
                }
                .tag(Mode.ranges)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Group {
                switch groups {
                case let .success(groups) where !groups.isEmpty:
                    Text(L("Makes %ld files from %ld pages.", groups.count, library.pageCount))
                case .failure(let error) where !ranges.isEmpty:
                    Text(error.localizedDescription).foregroundStyle(.red)
                default:
                    Text(L("Each comma-separated range becomes one file."))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { library.pageSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L("Split…")) { split() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((try? groups.get())?.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: size) { value in size = min(max(1, value), max(1, library.pageCount)) }
    }

    private func split() {
        guard let groups = try? groups.get(), !groups.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Split Here")
        panel.message = L("Choose a folder for the %ld files.", groups.count)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let written = try library.splitDocument(into: groups, folder: folder)
            library.pageSheet = nil
            library.showExportStatus(L("Split into %ld files.", written))
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            problem = error.localizedDescription
        }
    }
}
