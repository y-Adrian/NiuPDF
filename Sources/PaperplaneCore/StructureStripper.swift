import Foundation

/// Removes a tagged PDF's structure tree so that PDFKit can save page changes
/// quickly.
///
/// PDFKit resolves the marked-content structure (`/StructTreeRoot`, `/MarkInfo`)
/// page by page whenever it writes a tagged document. After a page is inserted
/// or removed the per-page structure references shift, so a save re-resolves
/// the whole tree and takes minutes on a large tagged document. Dropping the two
/// catalog entries makes the document untagged, after which saves stay fast and
/// the leftover `/StructParents` and content markers are harmlessly ignored.
public enum StructureStripper {
    /// Returns the PDF with an incremental update that drops the catalog's
    /// structure entries, or nil when the file is not tagged (or is encrypted,
    /// which an incremental update cannot touch).
    public static func strip(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .isoLatin1),
              let trailer = lastTrailer(in: text), !trailer.contains("/Encrypt"),
              let catalogNumber = reference("/Root", in: trailer) else { return nil }
        let objects = ButtonFieldRepair.dictionaryObjects(in: text)
        guard let catalog = objects[catalogNumber],
              catalog.contains("/StructTreeRoot") || catalog.contains("/MarkInfo") else { return nil }

        var stripped = catalog
        for pattern in [
            #"/StructTreeRoot\s+\d+\s+\d+\s+R"#,
            #"/MarkInfo\s+\d+\s+\d+\s+R"#,
            #"/MarkInfo\s*<<[^>]*>>"#,
        ] {
            stripped = stripped.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        guard stripped != catalog else { return nil }

        var output = data
        if output.last != UInt8(ascii: "\n") { output.append(UInt8(ascii: "\n")) }
        let offset = output.count
        output.append(Data("\(catalogNumber) 0 obj\n\(stripped)\nendobj\n".utf8))
        let xrefOffset = output.count
        var xref = "xref\n0 1\n0000000000 65535 f \n"
        xref += "\(catalogNumber) 1\n" + String(format: "%010d 00000 n \n", offset)
        var newTrailer = "<< /Size \(trailerInteger("/Size", in: trailer) ?? (objects.keys.max() ?? 0) + 1)"
        for key in ["/Root", "/Info"] {
            if let value = reference(key, in: trailer) { newTrailer += " \(key) \(value) 0 R" }
        }
        if let id = trailer.range(of: #"/ID\s*\[[^\]]*\]"#, options: .regularExpression) {
            newTrailer += " " + trailer[id]
        }
        if let previous = previousXref(in: text) { newTrailer += " /Prev \(previous)" }
        newTrailer += " >>"
        output.append(Data((xref + "trailer\n" + newTrailer + "\nstartxref\n\(xrefOffset)\n%%EOF\n").utf8))
        return output
    }

    // MARK: Reading

    private static func lastTrailer(in text: String) -> String? {
        guard let range = text.range(of: "trailer", options: .backwards) else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.range(of: "startxref") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    private static func previousXref(in text: String) -> Int? {
        guard let range = text.range(of: "startxref", options: .backwards) else { return nil }
        return Int(text[range.upperBound...].split(whereSeparator: \.isWhitespace).first ?? "")
    }

    private static func trailerInteger(_ key: String, in text: String) -> Int? {
        guard let range = text.range(of: key + #"\s+(\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst(key.count).trimmingCharacters(in: .whitespaces))
    }

    private static func reference(_ key: String, in text: String) -> Int? {
        guard let range = text.range(of: key + #"\s+\d+\s+0\s+R"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst(key.count).split(whereSeparator: \.isWhitespace).first ?? "")
    }
}
