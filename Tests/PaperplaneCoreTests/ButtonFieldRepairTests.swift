import PDFKit
import XCTest
@testable import PaperplaneCore

final class ButtonFieldRepairTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestCorpus/fixtures/\(name)")
    }

    private func buttons(_ document: PDFDocument) -> [PDFAnnotation] {
        document.page(at: 0)!.annotations.filter { $0.widgetFieldType == .button }
    }

    private func states(_ document: PDFDocument) -> [String] {
        buttons(document).map { "\($0.fieldName ?? "")/\($0.buttonWidgetStateString)=\($0.buttonWidgetState == .onState ? 1 : 0)" }
    }

    /// Writes as PDFKit does, then repairs with the buttons as the app holds them.
    private func saveAndReopen(_ document: PDFDocument) throws -> PDFDocument {
        let states = buttons(document).map {
            ButtonWidgetState(rect: $0.bounds, onName: $0.buttonWidgetStateString, isOn: $0.buttonWidgetState == .onState,
                              isRadio: $0.widgetControlType == .radioButtonControl)
        }
        let written = try XCTUnwrap(document.dataRepresentation())
        let repaired = try XCTUnwrap(ButtonFieldRepair.repair(written, buttons: states))
        return try XCTUnwrap(PDFDocument(data: repaired))
    }

    func testRadioGroupKeepsItsNamesAcrossSaves() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixture("acroform-fields.pdf")))
        let all = buttons(document)
        let red = try XCTUnwrap(all.first { $0.buttonWidgetStateString == "Red" })
        let blue = try XCTUnwrap(all.first { $0.buttonWidgetStateString == "Blue" })
        let agree = try XCTUnwrap(all.first { $0.fieldName == "agree" })
        // Setting a radio button off clears its group, so off goes first.
        red.buttonWidgetState = .offState
        blue.buttonWidgetState = .onState
        agree.buttonWidgetState = .onState

        // Without the repair, PDFKit calls the changed button "Yes".
        let plain = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        XCTAssertFalse(states(plain).contains("color/Blue=1"))

        let first = try saveAndReopen(document)
        XCTAssertEqual(states(first), ["agree/Yes=1", "color/Red=0", "color/Blue=1"])

        // Choosing the other button in the saved file, and saving again.
        let reopened = buttons(first)
        reopened.first { $0.buttonWidgetStateString == "Blue" }?.buttonWidgetState = .offState
        reopened.first { $0.buttonWidgetStateString == "Red" }?.buttonWidgetState = .onState
        let second = try saveAndReopen(first)
        XCTAssertEqual(states(second), ["agree/Yes=1", "color/Red=1", "color/Blue=0"])
        XCTAssertEqual(second.page(at: 0)!.annotations.first { $0.fieldName == "name" }?.widgetFieldType, .text, "Other fields are untouched.")
    }

    func testNothingToRepairLeavesTheFile() throws {
        let document = try XCTUnwrap(PDFDocument(url: fixture("acroform-fields.pdf")))
        let written = try XCTUnwrap(document.dataRepresentation())
        let state = ButtonWidgetState(rect: CGRect(x: 140, y: 516, width: 18, height: 18), onName: "Red", isOn: false, isRadio: true)
        XCTAssertNil(ButtonFieldRepair.repair(written, buttons: [state]), "Buttons written with their own appearances need nothing.")
        XCTAssertNil(ButtonFieldRepair.repair(written, buttons: []))
    }

    func testNames() {
        XCTAssertEqual(ButtonFieldRepair.encodedName("Blue"), "Blue")
        XCTAssertEqual(ButtonFieldRepair.encodedName("A B#"), "A#20B#23")
        XCTAssertEqual(ButtonFieldRepair.encodedName("是"), "#E6#98#AF")
    }
}
