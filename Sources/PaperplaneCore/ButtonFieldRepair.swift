import CoreGraphics
import Foundation

/// A check box or radio button as the app holds it when saving.
public struct ButtonWidgetState: Equatable, Sendable {
    public var rect: CGRect
    /// The name of the widget's "on" state, such as "Yes" or "Blue".
    public var onName: String
    public var isOn: Bool
    public var isRadio: Bool

    public init(rect: CGRect, onName: String, isOn: Bool, isRadio: Bool) {
        self.rect = rect
        self.onName = onName
        self.isOn = isOn
        self.isRadio = isRadio
    }
}

/// Repairs check boxes and radio buttons in a file PDFKit has written.
///
/// PDFKit writes a button whose state changed with one appearance instead of
/// one per state, `/AS /Off`, and its value as a string. Other readers still
/// show it, but its "on" name is lost: after reopening, every button of a
/// radio group is called "Yes", and choosing one turns them all on. This
/// appends an incremental update that gives such buttons an appearance for
/// each state again, the right `/AS`, and the field's value as a name.
public enum ButtonFieldRepair {
    /// The repaired file, or nil when nothing needs repair or the file cannot
    /// be repaired here (encrypted files: new objects would need encrypting).
    public static func repair(_ data: Data, buttons: [ButtonWidgetState]) -> Data? {
        guard !buttons.isEmpty, let text = String(data: data, encoding: .isoLatin1),
              let trailer = lastTrailer(in: text), !trailer.contains("/Encrypt") else { return nil }
        let objects = dictionaryObjects(in: text)
        var nextNumber = trailerInteger("/Size", in: trailer) ?? (objects.keys.max() ?? 0) + 1
        var updates: [Int: String] = [:]
        var fieldValues: [Int: String] = [:]
        var appended: [(Int, Data)] = []

        for (number, body) in objects.sorted(by: { $0.key < $1.key }) {
            guard body.contains("/Subtype /Widget"),
                  let rect = rectangle(in: body),
                  let button = buttons.first(where: { matches($0.rect, rect) }) else { continue }
            let parent = reference("/Parent", in: body)
            let fieldNumber = parent ?? number
            let fieldBody = parent.flatMap { objects[$0] } ?? body
            guard fieldBody.contains("/FT /Btn") || body.contains("/FT /Btn") else { continue }
            let name = encodedName(button.onName)
            let state = button.isOn ? name : "Off"
            if button.isOn || fieldValues[fieldNumber] == nil { fieldValues[fieldNumber] = state }

            var widget = body
            if let single = body.range(of: #"/AP\s*<<\s*/N\s+\d+\s+0\s+R\s*>>"#, options: .regularExpression) {
                // Written with one appearance: one for each state again.
                let size = CGSize(width: rect.width, height: rect.height)
                let onNumber = nextNumber, offNumber = nextNumber + 1
                nextNumber += 2
                appended.append((onNumber, appearance(size: size, radio: button.isRadio, on: true)))
                appended.append((offNumber, appearance(size: size, radio: button.isRadio, on: false)))
                widget.replaceSubrange(single, with: "/AP << /N << /\(name) \(onNumber) 0 R /Off \(offNumber) 0 R >> >>")
                if parent != nil { widget = removingValue(from: widget) }
            } else if appearanceState(in: body) == state {
                continue
            }
            // Written as read, a button can keep the state it was opened with.
            widget = replacing(#"/AS\s*/[^\s/<>\[\]()]*"#, in: widget, with: "")
            updates[number] = inserting("/AS /\(state)", into: widget)
        }

        // Fields whose value no longer matches their buttons.
        for (fieldNumber, value) in fieldValues where updates[fieldNumber] == nil {
            if let field = objects[fieldNumber], fieldValue(in: field) == value { fieldValues[fieldNumber] = nil }
        }
        guard !updates.isEmpty || !fieldValues.isEmpty else { return nil }

        for (fieldNumber, var value) in fieldValues {
            var field = updates[fieldNumber] ?? objects[fieldNumber] ?? ""
            guard !field.isEmpty else { continue }
            // A button left alone (written as it was read) may be the one that is on.
            if value == "Off" {
                for (number, kid) in objects where updates[number] == nil && reference("/Parent", in: kid) == fieldNumber {
                    if let state = kid.range(of: #"/AS\s*/[^\s/<>\[\]()]+"#, options: .regularExpression),
                       case let name = kid[state].split(separator: "/").last.map(String.init) ?? "Off", name != "Off" {
                        value = name
                    }
                }
            }
            field = removingValue(from: field)
            updates[fieldNumber] = inserting("/V /\(value)", into: field)
        }

        var output = data
        if output.last != UInt8(ascii: "\n") { output.append(UInt8(ascii: "\n")) }
        var offsets: [Int: Int] = [:]
        for (number, body) in updates.sorted(by: { $0.key < $1.key }) {
            offsets[number] = output.count
            output.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }
        for (number, stream) in appended {
            offsets[number] = output.count
            output.append(Data("\(number) 0 obj\n".utf8))
            output.append(stream)
            output.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = output.count
        var xref = "xref\n0 1\n0000000000 65535 f \n"
        for (number, offset) in offsets.sorted(by: { $0.key < $1.key }) {
            xref += "\(number) 1\n" + String(format: "%010d 00000 n \n", offset)
        }
        var newTrailer = "<< /Size \(nextNumber)"
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

    /// Repairs a file PDFKit has just written, in place, when it needs it.
    public static func repairFile(at url: URL, buttons: [ButtonWidgetState]) throws {
        guard !buttons.isEmpty, let repaired = repair(try Data(contentsOf: url), buttons: buttons) else { return }
        try repaired.write(to: url)
    }

    // MARK: Reading PDFKit's output

    /// Objects whose body is a dictionary, without streams, by number. Later
    /// definitions win, as in an incrementally updated file.
    static func dictionaryObjects(in text: String) -> [Int: String] {
        var objects: [Int: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"(?m)^(\d+) 0 obj\s*"#)
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = match.range.location + match.range.length
            guard let number = Int(ns.substring(with: match.range(at: 1))),
                  ns.length > start + 1, ns.substring(with: NSRange(location: start, length: 2)) == "<<",
                  let end = dictionaryEnd(in: ns, from: start) else { continue }
            let after = ns.substring(with: NSRange(location: end, length: min(20, ns.length - end)))
            guard !after.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("stream") else { continue }
            objects[number] = ns.substring(with: NSRange(location: start, length: end - start))
        }
        return objects
    }

    /// The index just past the `>>` closing the dictionary that starts at `start`.
    private static func dictionaryEnd(in text: NSString, from start: Int) -> Int? {
        var depth = 0
        var index = start
        var inString = 0
        while index < text.length - 1 {
            let c = text.character(at: index)
            if inString > 0 {
                if c == 0x5C { index += 2; continue }          // backslash escape
                if c == 0x28 { inString += 1 }                 // (
                if c == 0x29 { inString -= 1 }                 // )
                index += 1
                continue
            }
            if c == 0x28 { inString = 1; index += 1; continue }
            let next = text.character(at: index + 1)
            if c == 0x3C, next == 0x3C { depth += 1; index += 2; continue }  // <<
            if c == 0x3E, next == 0x3E {                                      // >>
                depth -= 1
                index += 2
                if depth == 0 { return index }
                continue
            }
            index += 1
        }
        return nil
    }

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

    private static func appearanceState(in text: String) -> String? {
        guard let range = text.range(of: #"/AS\s*/[^\s/<>\[\]()]*"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: "/").last.map(String.init)
    }

    /// A field's value when it is a name.
    private static func fieldValue(in text: String) -> String? {
        guard let range = text.range(of: #"/V\s*/[^\s/<>\[\]()]*"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: "/").last.map(String.init)
    }

    private static func rectangle(in text: String) -> CGRect? {
        guard let range = text.range(of: #"/Rect\s*\[[^\]]*\]"#, options: .regularExpression) else { return nil }
        let numbers = text[range].dropFirst(5).split(whereSeparator: { " []\n\r\t".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: min(numbers[0], numbers[2]), y: min(numbers[1], numbers[3]),
                      width: abs(numbers[2] - numbers[0]), height: abs(numbers[3] - numbers[1]))
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    // MARK: Writing

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    /// Removes a `/V` entry: a name, or a string without nested parentheses.
    private static func removingValue(from text: String) -> String {
        replacing(#"/V\s*(\((?:[^()\\]|\\.)*\)|/[^\s/<>\[\]()]*|<[0-9A-Fa-f\s]*>)"#, in: text, with: "")
    }

    /// `entry` added just inside the dictionary's opening `<<`.
    private static func inserting(_ entry: String, into dictionary: String) -> String {
        guard dictionary.hasPrefix("<<") else { return dictionary }
        return "<< " + entry + " " + dictionary.dropFirst(2)
    }

    /// A PDF name: characters outside printable ASCII and delimiters as #xx.
    static func encodedName(_ name: String) -> String {
        var result = ""
        for byte in name.utf8 {
            let scalar = Character(UnicodeScalar(byte))
            if byte > 0x20, byte < 0x7F, !"#/()<>[]{}%".contains(scalar) {
                result.append(scalar)
            } else {
                result += String(format: "#%02X", byte)
            }
        }
        return result.isEmpty ? "On" : result
    }

    /// A simple appearance: a circle with a dot for radio buttons, a square
    /// with a check mark for check boxes; the "off" state is the outline.
    private static func appearance(size: CGSize, radio: Bool, on: Bool) -> Data {
        let w = max(size.width, 1), h = max(size.height, 1)
        let side = min(w, h)
        let cx = w / 2, cy = h / 2
        func f(_ value: CGFloat) -> String { String(format: "%.2f", value) }
        var ops = "q 0.4 G 1 w "
        if radio {
            ops += circle(cx: cx, cy: cy, r: side / 2 - 1, format: f) + " S"
            if on { ops += " 0 g " + circle(cx: cx, cy: cy, r: side * 0.22, format: f) + " f" }
        } else {
            ops += "\(f(cx - side / 2 + 0.5)) \(f(cy - side / 2 + 0.5)) \(f(side - 1)) \(f(side - 1)) re S"
            if on {
                ops += " 0 G \(f(side * 0.09)) w 1 J 1 j \(f(cx - side * 0.28)) \(f(cy)) m \(f(cx - side * 0.06)) \(f(cy - side * 0.24)) l \(f(cx + side * 0.3)) \(f(cy + side * 0.26)) l S"
            }
        }
        ops += " Q"
        let content = Data(ops.utf8)
        var data = Data("<< /Type /XObject /Subtype /Form /BBox [0 0 \(f(w)) \(f(h))] /Length \(content.count) >>\nstream\n".utf8)
        data.append(content)
        data.append(Data("\nendstream".utf8))
        return data
    }

    private static func circle(cx: CGFloat, cy: CGFloat, r: CGFloat, format f: (CGFloat) -> String) -> String {
        let k = r * 0.5523
        return "\(f(cx + r)) \(f(cy)) m "
            + "\(f(cx + r)) \(f(cy + k)) \(f(cx + k)) \(f(cy + r)) \(f(cx)) \(f(cy + r)) c "
            + "\(f(cx - k)) \(f(cy + r)) \(f(cx - r)) \(f(cy + k)) \(f(cx - r)) \(f(cy)) c "
            + "\(f(cx - r)) \(f(cy - k)) \(f(cx - k)) \(f(cy - r)) \(f(cx)) \(f(cy - r)) c "
            + "\(f(cx + k)) \(f(cy - r)) \(f(cx + r)) \(f(cy - k)) \(f(cx + r)) \(f(cy)) c h"
    }
}
