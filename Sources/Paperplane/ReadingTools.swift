import AppKit
import AVFoundation
import NaturalLanguage
import SwiftUI
import Translation

/// Reads text aloud with the system voice for its language. One voice for the
/// whole app, as in other Mac apps: reading something new stops the last one.
@MainActor
final class SpeechReader: NSObject, ObservableObject {
    static let shared = SpeechReader()

    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance being read; callbacks for one it replaced are ignored.
    private var current: AVSpeechUtterance?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        current = utterance
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// A voice for the text's main language: the one chosen in System
    /// Settings when it speaks that language (nil uses it), otherwise the
    /// system's voice for the region of the user's own language list.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        // Speech voices name Chinese by region, not by script.
        let base: String
        let fallbackRegion: String
        switch language {
        case .simplifiedChinese: (base, fallbackRegion) = ("zh", "CN")
        case .traditionalChinese: (base, fallbackRegion) = ("zh", "TW")
        case .english: (base, fallbackRegion) = ("en", "US")
        default: (base, fallbackRegion) = (language.rawValue, "")
        }
        if language != .traditionalChinese, AVSpeechSynthesisVoice.currentLanguageCode().hasPrefix(base) { return nil }
        let preferredRegion = Locale.preferredLanguages.lazy
            .map { Locale(identifier: $0) }
            .first { $0.language.languageCode?.identifier == base }?
            .region?.identifier
        // A region with no voice of its own (English in China) falls back to the usual one.
        let regions = language == .traditionalChinese ? [fallbackRegion] : [preferredRegion, fallbackRegion].compactMap { $0 }
        let candidates = regions.filter { !$0.isEmpty }.map { "\(base)-\($0)" } + [base]
        return candidates.lazy.compactMap { AVSpeechSynthesisVoice(language: $0) }.first
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(base) }
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    /// The synthesizer can still report speaking when it calls back, so
    /// the state follows the utterance instead.
    private func ended(_ id: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == id else { return }
        self.current = nil
        isSpeaking = false
    }
}

extension ReaderLibrary {
    /// Edit ▸ Read Selection Aloud: the selected text, or nothing.
    func readSelectionAloud() {
        guard let text = pdfView?.currentSelection?.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        SpeechReader.shared.speak(text)
    }
}

/// The system translation popover for selected text (macOS 14.4 and later).
@MainActor
enum SelectionTranslator {
    static var isAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Shows the popover under `rect`, in `view`'s coordinates. A clear
    /// placeholder view over the text anchors it and leaves when it closes.
    static func show(_ text: String, below rect: NSRect, in view: NSView) {
        guard #available(macOS 14.4, *) else { return }
        let anchor = NSHostingView(rootView: AnyView(EmptyView()))
        anchor.rootView = AnyView(TranslationAnchor(text: text) { [weak anchor] in anchor?.removeFromSuperview() })
        anchor.frame = rect
        view.addSubview(anchor)
    }
}

@available(macOS 14.4, *)
private struct TranslationAnchor: View {
    let text: String
    let onClose: () -> Void
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .translationPresentation(isPresented: $isPresented, text: text, arrowEdge: .bottom)
            .onAppear { isPresented = true }
            .onChange(of: isPresented) { _, presented in
                if !presented { onClose() }
            }
    }
}

/// In the status bar while a voice reads.
struct ReadingIndicator: View {
    @ObservedObject private var reader = SpeechReader.shared

    var body: some View {
        if reader.isSpeaking {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                Text(L("· Reading Aloud"))
                Button(L("Stop")) { reader.stop() }
                    .buttonStyle(.link)
            }
        }
    }
}
