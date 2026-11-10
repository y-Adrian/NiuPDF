import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Saved signatures: transparent PNG files in the app's support folder, so
/// they are reused across documents and kept on this Mac only.
enum SignatureStore {
    static var folder: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("Paperplane/Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Newest first.
    static func all() -> [URL] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return files.filter { $0.pathExtension == "png" }.sorted { created($0) > created($1) }
    }

    @discardableResult
    static func save(_ image: NSImage) -> URL? {
        guard let folder, let data = pngData(image) else { return nil }
        let url = folder.appendingPathComponent(UUID().uuidString + ".png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

/// Turning drawn strokes, typed names and pictures into signature images:
/// transparent around the ink and trimmed to it.
enum SignatureRenderer {
    static let scale: CGFloat = 3

    static func image(strokes: [[CGPoint]], in size: CGSize, color: NSColor, width: CGFloat = 2.5) -> NSImage? {
        guard strokes.contains(where: { $0.count > 1 }) else { return nil }
        return render(size: size) { context in
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in strokes where stroke.count > 1 {
                context.addLines(between: stroke)
                context.strokePath()
            }
        }
    }

    static func image(text: String, fontName: String, color: NSColor) -> NSImage? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let font = NSFont(name: fontName, size: 64) ?? .systemFont(ofSize: 64)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        return render(size: CGSize(width: ceil(size.width) + 20, height: ceil(size.height) + 20)) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            string.draw(at: CGPoint(x: 10, y: 10))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A picture of a signature; near-white pixels become transparent when asked.
    static func image(picture: NSImage, removingWhite: Bool) -> NSImage? {
        guard let cgImage = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        if removingWhite {
            let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for index in 0..<(width * height) {
                let pixel = pixels + index * 4
                let lightness = min(pixel[0], pixel[1], pixel[2])
                if lightness > 225 {
                    pixel[0] = 0; pixel[1] = 0; pixel[2] = 0; pixel[3] = 0
                }
            }
        }
        guard let result = context.makeImage(), let trimmed = trim(result) else { return nil }
        return NSImage(cgImage: trimmed, size: CGSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale))
    }

    private static func render(size: CGSize, _ draw: (CGContext) -> Void) -> NSImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context)
        guard let image = context.makeImage(), let trimmed = trim(image) else { return nil }
        return NSImage(cgImage: trimmed, size: CGSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale))
    }

    /// Crops to the non-transparent pixels, keeping a small margin.
    static func trim(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let margin = Int(4 * scale)
        let rect = CGRect(x: max(0, minX - margin), y: max(0, minY - margin),
                          width: min(width, maxX + margin + 1) - max(0, minX - margin),
                          height: min(height, maxY + margin + 1) - max(0, minY - margin))
        return image.cropping(to: rect)
    }
}

extension ReaderLibrary {
    /// Places a signature on the current page, smaller than a picture.
    func placeSignature(_ image: NSImage) {
        insertImage(image, actionName: L("Add Signature"), maximumWidth: 0.3)
    }
}

/// Make a signature (draw, type or pick a picture) or reuse a saved one.
struct SignatureSheet: View {
    private enum Mode: Hashable { case draw, type, picture }

    @EnvironmentObject private var library: ReaderLibrary
    @State private var mode: Mode = .draw
    @State private var strokes: [[CGPoint]] = []
    @State private var typed = ""
    @State private var fontName = SignatureSheet.fonts.first?.name ?? "Snell Roundhand"
    @State private var picture: NSImage?
    @State private var removesWhite = true
    @State private var inkColor = Color.black
    @State private var saved = SignatureStore.all()
    @State private var keepsSignature = true

    static let padSize = CGSize(width: 440, height: 150)

    /// Handwriting fonts installed on this Mac, Latin and Chinese.
    static let fonts: [(name: String, title: String)] = [
        ("SnellRoundhand", "Snell Roundhand"), ("BradleyHandITCTT-Bold", "Bradley Hand"), ("Noteworthy-Light", "Noteworthy"),
        ("STXingkai", "行楷"), ("STKaiti", "楷体"), ("HannotateSC-W5", "手札体")
    ].filter { NSFont(name: $0.0, size: 12) != nil }.map { (name: $0.0, title: $0.1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Add Signature")).font(.headline)
            if !saved.isEmpty {
                Text(L("Saved signatures")).font(.subheadline.weight(.semibold))
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(saved, id: \.self) { url in savedTile(url) }
                    }
                }
                .frame(height: 74)
                Divider()
            }
            Picker("", selection: $mode) {
                Text(L("Handwrite")).tag(Mode.draw)
                Text(L("Type a Name")).tag(Mode.type)
                Text(L("Picture")).tag(Mode.picture)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .draw:
                    SignaturePad(strokes: $strokes, color: NSColor(inkColor))
                        .frame(width: Self.padSize.width, height: Self.padSize.height)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4)))
                        .overlay(alignment: .bottomLeading) {
                            Text(L("Sign here with the mouse or trackpad"))
                                .font(.caption).foregroundStyle(.gray).padding(8)
                        }
                case .type:
                    TextField(L("Your name"), text: $typed)
                        .textFieldStyle(.roundedBorder)
                    Picker(L("Font:"), selection: $fontName) {
                        ForEach(Self.fonts, id: \.name) { font in Text(font.title).tag(font.name) }
                    }
                    Text(typed.isEmpty ? L("Your name") : typed)
                        .font(.custom(fontName, size: 40))
                        .foregroundStyle(typed.isEmpty ? Color.gray : inkColor)
                        .frame(width: Self.padSize.width, height: 90)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                case .picture:
                    HStack {
                        Button(L("Choose Picture…"), action: choosePicture)
                        Toggle(L("Make white background transparent"), isOn: $removesWhite)
                            .toggleStyle(.checkbox)
                    }
                    if let preview = makeImage() {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: Self.padSize.width, maxHeight: 110)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            HStack {
                if mode != .picture {
                    Text(L("Color:"))
                    ForEach([Color.black, Color(red: 0.05, green: 0.2, blue: 0.65)], id: \.self) { color in
                        Circle().fill(color).frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: inkColor == color ? 2 : 0).padding(-3))
                            .onTapGesture { inkColor = color }
                    }
                }
                if mode == .draw {
                    Button(L("Clear")) { strokes = [] }
                }
                Spacer()
                Toggle(L("Save for later"), isOn: $keepsSignature).toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { library.isAddingSignature = false }
                    .keyboardShortcut(.cancelAction)
                Button(L("Place on Page")) { place() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(makeImage() == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func savedTile(_ url: URL) -> some View {
        Button {
            guard let image = NSImage(contentsOf: url) else { return }
            library.placeSignature(image)
            library.isAddingSignature = false
        } label: {
            Group {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
            .frame(width: 130, height: 60)
            .padding(4)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(L("Place this signature"))
        .contextMenu {
            Button(L("Delete Signature"), role: .destructive) {
                SignatureStore.delete(url)
                saved = SignatureStore.all()
            }
        }
    }

    private func makeImage() -> NSImage? {
        switch mode {
        case .draw: SignatureRenderer.image(strokes: strokes, in: Self.padSize, color: NSColor(inkColor))
        case .type: SignatureRenderer.image(text: typed, fontName: fontName, color: NSColor(inkColor))
        case .picture: picture.flatMap { SignatureRenderer.image(picture: $0, removingWhite: removesWhite) }
        }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        picture = NSImage(contentsOf: url)
    }

    private func place() {
        guard let image = makeImage() else { return }
        if keepsSignature { SignatureStore.save(image) }
        library.placeSignature(image)
        library.isAddingSignature = false
    }
}

/// A white pad that records strokes in its own coordinates (origin bottom left).
struct SignaturePad: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]
    let color: NSColor

    func makeNSView(context: Context) -> PadView {
        let view = PadView()
        view.onChange = { strokes = $0 }
        return view
    }

    func updateNSView(_ view: PadView, context: Context) {
        view.color = color
        if view.strokes != strokes { view.strokes = strokes; view.needsDisplay = true }
        view.onChange = { strokes = $0 }
    }

    final class PadView: NSView {
        var strokes: [[CGPoint]] = []
        var color: NSColor = .black { didSet { needsDisplay = true } }
        var onChange: (([[CGPoint]]) -> Void)?

        override func mouseDown(with event: NSEvent) {
            strokes.append([convert(event.locationInWindow, from: nil)])
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard !strokes.isEmpty else { return }
            strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            onChange?(strokes)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(2.5)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in strokes where stroke.count > 1 {
                context.addLines(between: stroke)
                context.strokePath()
            }
        }
    }
}
