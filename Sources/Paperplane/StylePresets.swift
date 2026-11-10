import AppKit
import SwiftUI

/// A saved annotation style: a tool with its color and opacity, plus the line
/// width of drawings and shapes or the font of text boxes.
struct StylePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: String
    var colorHex: String
    var opacity: Double
    var lineWidth: Double?
    var fontFamily: String?
    var fontSize: Double?

    var annotationTool: AnnotationTool? { AnnotationTool(rawValue: tool) }

    var color: MarkupColor {
        let hex = colorHex.uppercased()
        return (MarkupColor.allCases + MarkupColor.drawingCases).first { $0.hex == hex } ?? MarkupColor(hex: hex, title: "#" + hex)
    }

    /// Such as "Highlight · Yellow · 50%" or "Draw · Red · 100% · 3 pt".
    var title: String {
        var parts = [annotationTool?.title ?? tool, color.title, L("%ld%%", Int((opacity * 100).rounded()))]
        if let lineWidth { parts.append(L("%ld pt", Int(lineWidth))) }
        if annotationTool == .textBox {
            parts.append(FontChoices.displayName(fontFamily))
            if let fontSize { parts.append(L("%ld pt", Int(fontSize))) }
        }
        return parts.joined(separator: " · ")
    }

    /// The same style, ignoring the identity.
    func hasSameStyle(as other: StylePreset) -> Bool {
        var copy = other
        copy.id = id
        return copy == self
    }
}

/// Presets shared by every window, kept across launches.
@MainActor
final class StylePresetStore: ObservableObject {
    static let shared = StylePresetStore()
    private static let key = "stylePresets"

    @Published private(set) var presets: [StylePreset] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([StylePreset].self, from: data) {
            presets = saved
        }
    }

    /// Adds a preset unless one with the same style exists.
    func add(_ preset: StylePreset) {
        guard !presets.contains(where: { $0.hasSameStyle(as: preset) }) else { return }
        presets.append(preset)
        save()
    }

    func remove(_ preset: StylePreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func contains(styleOf preset: StylePreset) -> Bool {
        presets.contains { $0.hasSameStyle(as: preset) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension ReaderLibrary {
    /// The active tool's current style as a preset; nil for tools without one.
    var currentStylePreset: StylePreset? {
        let tool = activeTool
        guard tool != .select, tool != .note else { return nil }
        return StylePreset(
            tool: tool.rawValue,
            colorHex: color(for: tool).hex,
            opacity: Double(opacity(for: tool)),
            lineWidth: tool == .ink || tool.isShape ? Double(strokeWidth) : nil,
            fontFamily: tool == .textBox ? textFontFamily : nil,
            fontSize: tool == .textBox ? Double(textFontSize) : nil
        )
    }

    /// Makes the preset's tool active with its style. With text selected, a
    /// markup preset marks it, as picking a color in the toolbar does.
    func applyPreset(_ preset: StylePreset) {
        guard let tool = preset.annotationTool else { return }
        isAnnotationBarVisible = true
        chooseOpacity(CGFloat(preset.opacity), for: tool)
        if let width = preset.lineWidth { chooseStrokeWidth(CGFloat(width)) }
        if tool == .textBox { chooseTextFont(family: preset.fontFamily, size: CGFloat(preset.fontSize ?? Double(Self.textBoxFontSize))) }
        chooseColor(preset.color, for: tool)
        activeTool = tool
    }
}

/// The toolbar's preset menu: apply a preset, save the current style, or
/// delete presets.
struct StylePresetMenu: View {
    @EnvironmentObject private var library: ReaderLibrary
    @ObservedObject private var store = StylePresetStore.shared

    var body: some View {
        let current = library.currentStylePreset
        Menu {
            if store.presets.isEmpty {
                Text(L("No saved styles"))
            }
            ForEach(store.presets) { preset in
                Button { library.applyPreset(preset) } label: {
                    Label { Text(preset.title) } icon: { Image(nsImage: Self.swatch(preset)) }
                }
            }
            Divider()
            Button(L("Save Current Style")) {
                if let current { store.add(current) }
            }
            .disabled(current.map(store.contains(styleOf:)) ?? true)
            if !store.presets.isEmpty {
                Menu(L("Delete Style")) {
                    ForEach(store.presets) { preset in
                        Button(preset.title) { store.remove(preset) }
                    }
                }
            }
        } label: {
            Image(systemName: "swatchpalette")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Saved Styles"))
        .accessibilityLabel(L("Saved Styles"))
    }

    /// A dot in the preset's color and opacity; menus show images, not shapes.
    private static func swatch(_ preset: StylePreset) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            preset.color.nsColor.withAlphaComponent(CGFloat(preset.opacity)).setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 0.75
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
