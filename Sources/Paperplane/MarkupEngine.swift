import AppKit
import PDFKit

/// Text markup (highlight, underline, squiggly, strike-out) modeled as the set of page
/// characters it covers. Working on characters instead of rectangles lets one
/// selection become one annotation, and lets overlapping markup be merged or
/// partly erased the way mainstream PDF editors do.
enum MarkupEngine {
    /// Character ranges written by this app as "location:length …". Other readers
    /// ignore the key; markup from other apps is mapped back from its quads.
    private static let rangesKey = PDFAnnotationKey(rawValue: "/PaperplaneRanges")

    static let markupTypeNames: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly"]

    /// Squiggly underlines are written as underlines carrying this key. PDFKit
    /// writes `/Squiggly` with an empty appearance and no quads, so other
    /// readers would show nothing; they show these as plain underlines, and
    /// the page overlay here draws the wave.
    private static let squigglyKey = PDFAnnotationKey(rawValue: "/PaperplaneSquiggly")

    /// Squiggly markup: ours, or a native `/Squiggly` from another app, which
    /// PDFKit does not draw either.
    static func isSquiggly(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Squiggly" || (annotation.type == "Underline" && annotation.value(forAnnotationKey: squigglyKey) != nil)
    }

    /// The markup tool an annotation was made with, or nil for other kinds.
    static func tool(of annotation: PDFAnnotation) -> AnnotationTool? {
        switch annotation.type {
        case "Highlight": .highlight
        case "Underline", "Squiggly": isSquiggly(annotation) ? .squiggly : .underline
        case "StrikeOut": .strikeOut
        default: nil
        }
    }

    static func subtype(for tool: AnnotationTool) -> PDFAnnotationSubtype {
        switch tool {
        case .underline, .squiggly: .underline
        case .strikeOut: .strikeOut
        default: .highlight
        }
    }

    static func isMarkup(_ annotation: PDFAnnotation) -> Bool {
        markupTypeNames.contains(annotation.type ?? "")
    }

    static func characters(of selection: PDFSelection, on page: PDFPage) -> IndexSet {
        var characters = IndexSet()
        for index in 0..<selection.numberOfTextRanges(on: page) {
            let range = selection.range(at: index, on: page)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            characters.insert(integersIn: range.location..<(range.location + range.length))
        }
        return characters
    }

    static func characters(of annotation: PDFAnnotation, on page: PDFPage) -> IndexSet {
        if let raw = annotation.value(forAnnotationKey: rangesKey) as? String {
            var characters = IndexSet()
            for token in raw.split(separator: " ") {
                let parts = token.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, parts[1] > 0 else { continue }
                characters.insert(integersIn: parts[0]..<(parts[0] + parts[1]))
            }
            if !characters.isEmpty { return characters }
        }
        // Shrink each quad vertically so a neighbouring line's glyphs are not picked up.
        var characters = IndexSet()
        for rect in lineRects(of: annotation) {
            let probe = rect.insetBy(dx: 0, dy: rect.height * 0.3)
            guard let selection = page.selection(for: probe) else { continue }
            characters.formUnion(self.characters(of: selection, on: page))
        }
        return characters
    }

    /// The page-space rectangles of each quad (one per line), or the bounds when there are none.
    static func lineRects(of annotation: PDFAnnotation) -> [CGRect] {
        let points = (annotation.quadrilateralPoints ?? []).map(\.pointValue)
        guard points.count >= 4 else { return [annotation.bounds] }
        let origin = annotation.bounds.origin
        return stride(from: 0, to: points.count - 3, by: 4).map { start in
            let quad = points[start..<(start + 4)]
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(
                x: origin.x + xs.min()!,
                y: origin.y + ys.min()!,
                width: xs.max()! - xs.min()!,
                height: ys.max()! - ys.min()!
            )
        }
    }

    /// Characters that are not whitespace; used so a trailing space or line break
    /// in a selection does not decide whether text is "already marked".
    static func visibleCharacters(_ characters: IndexSet, on page: PDFPage) -> IndexSet {
        guard let text = page.string as NSString? else { return characters }
        return characters.filteredIndexSet { index in
            guard index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    /// Builds one markup annotation covering `characters`, with one quad per text line.
    static func makeAnnotation(
        tool: AnnotationTool,
        color: NSColor,
        characters: IndexSet,
        on page: PDFPage
    ) -> PDFAnnotation? {
        var lines: [CGRect] = []
        for range in characters.rangeView {
            guard let selection = page.selection(for: NSRange(location: range.lowerBound, length: range.count)) else { continue }
            lines.append(contentsOf: lineRects(of: selection, on: page))
        }
        return buildAnnotation(tool: tool, color: color, lines: lines, characters: characters)
    }

    /// Builds markup from a selection's visual lines, for selections whose
    /// character ranges cannot be mapped back (for example text inside tables).
    static func makeAnnotation(
        tool: AnnotationTool,
        color: NSColor,
        selection: PDFSelection,
        on page: PDFPage
    ) -> PDFAnnotation? {
        buildAnnotation(tool: tool, color: color, lines: lineRects(of: selection, on: page), characters: nil)
    }

    /// The visual rectangles of a selection's lines, skipping empty lines.
    private static func lineRects(of selection: PDFSelection, on page: PDFPage) -> [CGRect] {
        let lines = selection.selectionsByLine().compactMap { line -> CGRect? in
            guard !(line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rect = line.bounds(for: page)
            return (!rect.isNull && !rect.isEmpty) ? rect : nil
        }
        if lines.isEmpty {
            // Some text (for example table cells) yields a null per-line rect;
            // fall back to the whole selection's bounds.
            let rect = selection.bounds(for: page)
            return (!rect.isNull && !rect.isEmpty) ? [rect] : []
        }
        return lines
    }

    /// Builds the annotation for `lines`, recording `characters` when known so
    /// overlapping markup can be merged or partly erased later.
    private static func buildAnnotation(
        tool: AnnotationTool,
        color: NSColor,
        lines: [CGRect],
        characters: IndexSet?
    ) -> PDFAnnotation? {
        guard let first = lines.first else { return nil }
        let bounds = lines.dropFirst().reduce(first) { $0.union($1) }

        let type = subtype(for: tool)
        let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        if tool == .squiggly { annotation.setValue("1", forAnnotationKey: squigglyKey) }
        if type == .underline {
            let border = PDFBorder()
            border.lineWidth = 2
            annotation.border = border
        }
        // Quad points are relative to the annotation origin, ordered
        // top-left, top-right, bottom-left, bottom-right for each line.
        annotation.quadrilateralPoints = lines.flatMap { line -> [NSValue] in
            let strikeOffset = type == .strikeOut ? min(3, line.height * 0.2) : 0
            let left = line.minX - bounds.minX
            let right = line.maxX - bounds.minX
            let bottom = line.minY - bounds.minY
            let top = max(bottom, line.maxY - bounds.minY - strikeOffset)
            return [
                NSValue(point: CGPoint(x: left, y: top)),
                NSValue(point: CGPoint(x: right, y: top)),
                NSValue(point: CGPoint(x: left, y: bottom)),
                NSValue(point: CGPoint(x: right, y: bottom))
            ]
        }
        annotation.color = color
        if let characters {
            annotation.setValue(
                characters.rangeView.map { "\($0.lowerBound):\($0.count)" }.joined(separator: " "),
                forAnnotationKey: rangesKey
            )
        }
        return annotation
    }

    /// Splits characters into runs, treating gaps that are only whitespace as part
    /// of the run, so erasing the middle of a highlight leaves two clean pieces.
    static func runs(of characters: IndexSet, on page: PDFPage) -> [IndexSet] {
        let text = page.string as NSString?
        var runs: [IndexSet] = []
        var current = IndexSet()
        var previousEnd: Int?
        for range in characters.rangeView {
            if let previousEnd, previousEnd < range.lowerBound,
               !gapIsWhitespace(previousEnd..<range.lowerBound, in: text) {
                runs.append(current)
                current = IndexSet()
            }
            current.insert(integersIn: range)
            previousEnd = range.upperBound
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func gapIsWhitespace(_ gap: Range<Int>, in text: NSString?) -> Bool {
        guard let text else { return false }
        return gap.allSatisfy { index in
            guard index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}
