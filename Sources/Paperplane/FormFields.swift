import PaperplaneCore
import PDFKit

/// Filling in forms. PDFKit edits the fields itself, as the user clicks and
/// types, and registers each change for undo in the view's undo manager; this
/// notices the changes so the document counts as edited and is saved.
extension ReaderLibrary {
    /// Posted by PDFKit for each change of a field's value, with the document.
    static let formDidChangeValue = Notification.Name("PDFFormDidChangeValue")

    /// The check boxes and radio buttons, for `ButtonFieldRepair` after saving.
    func buttonWidgetStates(in document: PDFDocument? = nil) -> [ButtonWidgetState] {
        (document ?? self.document).map(Self.buttonWidgetStates(of:)) ?? []
    }

    /// As `buttonWidgetStates(in:)`, for any document.
    nonisolated static func buttonWidgetStates(of document: PDFDocument) -> [ButtonWidgetState] {
        buttonWidgetStates(on: (0..<document.pageCount).compactMap { document.page(at: $0) })
    }

    /// The buttons on some pages. Extract, Split and Merge read them on the
    /// source pages: a copied button no longer knows whether it is on.
    nonisolated static func buttonWidgetStates(on pages: [PDFPage]) -> [ButtonWidgetState] {
        pages.flatMap { page in
            page.annotations.compactMap { widget -> ButtonWidgetState? in
                guard widget.type == "Widget", widget.widgetFieldType == .button,
                      widget.widgetControlType == .radioButtonControl || widget.widgetControlType == .checkBoxControl else { return nil }
                return ButtonWidgetState(rect: widget.bounds, onName: widget.buttonWidgetStateString,
                                         isOn: widget.buttonWidgetState == .onState,
                                         isRadio: widget.widgetControlType == .radioButtonControl)
            }
        }
    }
}
