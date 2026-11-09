import AppKit
import PDFKit

/// Where an annotation sits and what shape it has: its bounds, plus the
/// drawing's paths or the line's end points, which are relative to the bounds.
struct AnnotationGeometry {
    var bounds: CGRect
    var paths: [NSBezierPath]?
    var start: CGPoint
    var end: CGPoint

    init(_ annotation: PDFAnnotation) {
        bounds = annotation.bounds
        paths = annotation.type == "Ink" ? annotation.paths?.compactMap { $0.copy() as? NSBezierPath } : nil
        start = annotation.startPoint
        end = annotation.endPoint
    }

    func apply(to annotation: PDFAnnotation) {
        annotation.bounds = bounds
        if let paths {
            for path in annotation.paths ?? [] { annotation.remove(path) }
            for path in paths { annotation.add((path.copy() as? NSBezierPath) ?? path) }
        }
        if annotation.type == "Line" {
            annotation.startPoint = start
            annotation.endPoint = end
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> AnnotationGeometry {
        var moved = self
        moved.bounds = bounds.offsetBy(dx: dx, dy: dy)
        return moved
    }
}

enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case lineStart, lineEnd
}

/// Selecting and editing annotations: resize, nudge, copy, paste, duplicate
/// and delete. Geometry changes undo through one snapshot-based step.
extension ReaderLibrary {
    /// Drawings, shapes and text boxes have handles; other annotations can be
    /// selected for copying or deleting but keep their size.
    static func isResizable(_ annotation: PDFAnnotation) -> Bool { isMovable(annotation) }

    /// Annotations that can be copied and pasted elsewhere. Text markup is tied
    /// to the text under it, so it is not.
    static func isCopyable(_ annotation: PDFAnnotation) -> Bool {
        isMovable(annotation) || annotation.type == "Text"
    }

    static let minimumAnnotationSize: CGFloat = 6

    // MARK: Selection

    func isSelected(_ annotation: PDFAnnotation) -> Bool {
        selectedAnnotations.contains { $0 === annotation }
    }

    /// Selects an annotation; with `extending` (⇧-click, ⌘-click in the list)
    /// it is added to or removed from the selection.
    func select(_ annotation: PDFAnnotation, extending: Bool) {
        if extending {
            if isSelected(annotation) {
                selectedAnnotations.removeAll { $0 === annotation }
            } else {
                selectedAnnotations.append(annotation)
            }
        } else if selectedAnnotations.count != 1 || !isSelected(annotation) {
            selectedAnnotations = [annotation]
        }
    }

    func clearAnnotationSelection() {
        if !selectedAnnotations.isEmpty { selectedAnnotations = [] }
    }

    // MARK: Geometry

    /// The handles of a resizable annotation, in page coordinates.
    static func handles(for annotation: PDFAnnotation) -> [(ResizeHandle, CGPoint)] {
        if annotation.type == "Line" {
            let origin = annotation.bounds.origin
            return [
                (.lineStart, CGPoint(x: origin.x + annotation.startPoint.x, y: origin.y + annotation.startPoint.y)),
                (.lineEnd, CGPoint(x: origin.x + annotation.endPoint.x, y: origin.y + annotation.endPoint.y))
            ]
        }
        let r = annotation.bounds
        return [
            (.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.top, CGPoint(x: r.midX, y: r.maxY)),
            (.topRight, CGPoint(x: r.maxX, y: r.maxY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.minY)), (.bottom, CGPoint(x: r.midX, y: r.minY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.left, CGPoint(x: r.minX, y: r.midY))
        ]
    }

    /// The geometry after dragging `handle` to `point` (page coordinates).
    /// Page y grows upward, so "top" is the larger y.
    static func resized(_ original: AnnotationGeometry, type: String, handle: ResizeHandle, to point: CGPoint) -> AnnotationGeometry {
        var result = original
        if type == "Line" {
            var start = CGPoint(x: original.bounds.minX + original.start.x, y: original.bounds.minY + original.start.y)
            var end = CGPoint(x: original.bounds.minX + original.end.x, y: original.bounds.minY + original.end.y)
            if handle == .lineStart { start = point } else { end = point }
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            result.bounds = rect.insetBy(dx: -10, dy: -10)
            result.start = CGPoint(x: start.x - result.bounds.minX, y: start.y - result.bounds.minY)
            result.end = CGPoint(x: end.x - result.bounds.minX, y: end.y - result.bounds.minY)
            return result
        }
        let r = original.bounds
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        let side = minimumAnnotationSize
        if [.topLeft, .left, .bottomLeft].contains(handle) { minX = min(point.x, maxX - side) }
        if [.topRight, .right, .bottomRight].contains(handle) { maxX = max(point.x, minX + side) }
        if [.topLeft, .top, .topRight].contains(handle) { maxY = max(point.y, minY + side) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { minY = min(point.y, maxY - side) }
        result.bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let paths = original.paths, r.width > 0, r.height > 0 {
            // Drawings scale with their box; paths are relative to its origin.
            let scale = AffineTransform(scaleByX: result.bounds.width / r.width, byY: result.bounds.height / r.height)
            result.paths = paths.compactMap { path in
                let scaled = path.copy() as? NSBezierPath
                scaled?.transform(using: scale)
                return scaled
            }
        }
        return result
    }

    /// Records a finished move, resize or nudge as one undo step. The
    /// annotations already show their new geometry.
    func commitGeometry(_ annotations: [PDFAnnotation], from originals: [AnnotationGeometry], actionName: String) {
        let finals = annotations.map(AnnotationGeometry.init)
        guard zip(finals, originals).contains(where: { $0.bounds != $1.bounds || $0.start != $1.start || $0.end != $1.end }) else { return }
        pdfView?.undoManager?.registerUndo(withTarget: self) { target in
            for (annotation, geometry) in zip(annotations, originals) { geometry.apply(to: annotation) }
            target.commitGeometry(annotations, from: finals, actionName: actionName)
        }
        pdfView?.undoManager?.setActionName(actionName)
        annotationsDidChange()
    }

    /// Arrow keys: moves the selected drawings, shapes and text boxes.
    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        let movable = selectedAnnotations.filter(Self.isMovable)
        guard !movable.isEmpty else { return }
        let originals = movable.map(AnnotationGeometry.init)
        for (annotation, geometry) in zip(movable, originals) {
            geometry.offsetBy(dx: dx, dy: dy).apply(to: annotation)
        }
        commitGeometry(movable, from: originals, actionName: L("Move Annotation"))
    }

    // MARK: Clipboard

    /// A new annotation equal to `annotation`. `PDFAnnotation.copy()` is not
    /// enough: PDFKit shows such copies but leaves them out when it writes the
    /// file. A new annotation built from the original's dictionary is written,
    /// but takes the original's rectangle, so the geometry is applied after.
    static func freshCopy(of annotation: PDFAnnotation) -> PDFAnnotation? {
        guard let type = annotation.type else { return nil }
        var properties = annotation.annotationKeyValues
        // The page and popup belong to the original.
        properties.removeValue(forKey: "/P")
        properties.removeValue(forKey: "/Popup")
        let copy = PDFAnnotation(
            bounds: annotation.bounds,
            forType: PDFAnnotationSubtype(rawValue: "/" + type),
            withProperties: properties
        )
        AnnotationGeometry(annotation).apply(to: copy)
        if type == "FreeText" {
            copy.font = annotation.font
            copy.fontColor = annotation.fontColor
        }
        copy.shouldDisplay = true
        return copy
    }

    var hasCopyableSelection: Bool { selectedAnnotations.contains(where: Self.isCopyable) }
    var canPasteAnnotations: Bool { document != nil && !AppModel.shared.annotationClipboard.isEmpty }

    /// ⌘C with annotations selected; false lets the text copy run instead.
    @discardableResult
    func copySelectedAnnotations() -> Bool {
        let copyable = selectedAnnotations.filter(Self.isCopyable)
        guard !copyable.isEmpty else { return false }
        commitPendingEdits?()
        withNativeNotesRestored {
            AppModel.shared.annotationClipboard = copyable.compactMap { annotation in
                Self.freshCopy(of: annotation).map { ($0, annotation.page) }
            }
        }
        AppModel.shared.pasteOffset = 0
        return true
    }

    @discardableResult
    func cutSelectedAnnotations() -> Bool {
        guard copySelectedAnnotations() else { return false }
        deleteSelectedAnnotations(actionName: L("Cut"))
        return true
    }

    /// Pastes onto the page being worked on: the selection's page while it is
    /// on screen, otherwise the current page. On the page the copies came from
    /// they are shifted; on another page they keep their place.
    @discardableResult
    func pasteAnnotations() -> Bool {
        guard canPasteAnnotations, let page = pasteTargetPage else { return false }
        let clipboard = AppModel.shared.annotationClipboard
        let model = AppModel.shared
        if clipboard.contains(where: { $0.sourcePage === page }) { model.pasteOffset += 12 }
        let offset = clipboard.contains(where: { $0.sourcePage === page }) ? model.pasteOffset : 0
        let pasted = place(clipboard.map(\.annotation), on: page, offset: offset, actionName: L("Paste"))
        return !pasted.isEmpty
    }

    private var pasteTargetPage: PDFPage? {
        if let selectionPage = selectedAnnotations.first?.page,
           pdfView?.visiblePages.contains(where: { $0 === selectionPage }) == true {
            return selectionPage
        }
        return pdfView?.currentPage ?? document?.page(at: currentPageIndex)
    }

    /// ⌘D: copies of the selection next to the originals, leaving the clipboard alone.
    func duplicateSelectedAnnotations() {
        let copyable = selectedAnnotations.filter(Self.isCopyable)
        guard let page = copyable.first?.page else { return }
        let sources = withNativeNotesRestored { copyable.filter { $0.page === page }.compactMap(Self.freshCopy) }
        _ = place(sources, on: page, offset: 12, actionName: L("Duplicate"))
    }

    private func place(_ sources: [PDFAnnotation], on page: PDFPage, offset: CGFloat, actionName: String) -> [PDFAnnotation] {
        let pageBounds = page.bounds(for: .mediaBox)
        let copies: [PDFAnnotation] = sources.compactMap { source in
            guard let copy = Self.freshCopy(of: source) else { return nil }
            var geometry = AnnotationGeometry(copy).offsetBy(dx: offset, dy: -offset)
            // Keep pasted annotations on the page.
            geometry.bounds.origin.x = min(max(geometry.bounds.minX, pageBounds.minX), pageBounds.maxX - geometry.bounds.width)
            geometry.bounds.origin.y = min(max(geometry.bounds.minY, pageBounds.minY), pageBounds.maxY - geometry.bounds.height)
            geometry.apply(to: copy)
            return copy
        }
        guard !copies.isEmpty else { return [] }
        commitPendingEdits?()
        for copy in copies where copy.type == "Text" || Self.overlayDrawnTypes.contains(copy.type ?? "") {
            handOverToOverlay(copy)
        }
        recordAnnotationEdit(actionName, pages: [page]) {
            for copy in copies { page.addAnnotation(copy) }
        }
        selectedAnnotations = copies
        return copies
    }

    // MARK: Deleting

    /// Deletes every selected annotation, across pages, as one undo step.
    @discardableResult
    func deleteSelectedAnnotations(actionName: String? = nil) -> Bool {
        let doomed = selectedAnnotations.filter { $0.page != nil }
        guard !doomed.isEmpty else { return false }
        commitPendingEdits?()
        var pages: [PDFPage] = []
        for annotation in doomed {
            if let page = annotation.page, !pages.contains(where: { $0 === page }) { pages.append(page) }
        }
        let name = actionName ?? (doomed.count == 1 ? L("Delete Annotation") : L("Delete %ld Annotations", doomed.count))
        recordAnnotationEdit(name, pages: pages) {
            for annotation in doomed { annotation.page?.removeAnnotation(annotation) }
        }
        selectedAnnotations = []
        return true
    }
}
