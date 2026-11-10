import AppKit
import PDFKit
import PaperplaneCore
import SwiftUI

enum DocumentProtectionError: LocalizedError {
    case restricted

    var errorDescription: String? {
        L("This document restricts changes, so they can’t be saved to it. Enter its permissions password to lift the restrictions, then save again.")
    }
}

/// Passwords and restrictions: File ▸ Set Password and Remove Password, and
/// read-only behavior while the file's restrictions apply.
extension ReaderLibrary {
    /// False while the file forbids annotations to readers without the
    /// permissions password; PDFKit would leave such changes out of the file.
    var canAnnotate: Bool {
        guard let document else { return false }
        return document.permissionsStatus == .owner || document.allowsCommenting
    }

    /// False while the file forbids inserting, deleting, rotating or moving pages.
    var canChangePages: Bool {
        guard let document else { return false }
        return document.permissionsStatus == .owner || document.allowsDocumentAssembly
    }

    var canPrint: Bool {
        guard let document else { return false }
        return document.permissionsStatus == .owner || document.allowsPrinting
    }

    /// Copying text, and exporting pages as images, which extracts the same content.
    var canCopy: Bool {
        guard let document else { return false }
        return document.permissionsStatus == .owner || document.allowsCopying
    }

    /// Copying pages into another file drops the source's restrictions, so it
    /// needs the right to copy its content.
    static func allowsCopyingPages(of document: PDFDocument) -> Bool {
        document.permissionsStatus == .owner || document.allowsCopying
    }

    /// The file has an open password or restrictions.
    var isPasswordProtected: Bool { requiresOpenPassword || readerRestrictions != nil }

    /// Why editing is limited right now, for the bar above the page.
    var restrictionMessage: String? {
        guard document != nil else { return nil }
        let forbidden = [
            canAnnotate ? nil : L("annotations"),
            canChangePages ? nil : L("page changes"),
            canPrint ? nil : L("printing"),
            canCopy ? nil : L("copying")
        ].compactMap { $0 }
        guard !forbidden.isEmpty else { return nil }
        return L("This document doesn’t allow %@.", ListFormatter.localizedString(byJoining: forbidden))
    }

    private var needsPermissionsPassword: Bool {
        readerRestrictions != nil && document?.permissionsStatus != .owner
    }

    /// Asks for the permissions password until it lifts the restrictions or
    /// the user cancels.
    @discardableResult
    func askToLiftRestrictions() -> Bool {
        var message = L("“%@” restricts what may be changed. Enter its permissions password to lift the restrictions.", displayName)
        while true {
            let alert = NSAlert()
            alert.messageText = L("Enter Permissions Password")
            alert.informativeText = message
            alert.addButton(withTitle: L("Unlock"))
            alert.addButton(withTitle: L("Cancel"))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if liftRestrictions(with: field.stringValue) { return true }
            message = L("Incorrect password. Try again.")
        }
    }

    /// File ▸ Set Password; changing a restricted file's passwords needs its
    /// permissions password first.
    func beginEditingPassword() {
        guard document != nil else { return }
        if needsPermissionsPassword, !askToLiftRestrictions() { return }
        isEditingPassword = true
    }

    /// Writes the passwords into the file; returns why not, or nil when done.
    func applyPassword(_ settings: PDFPasswordSettings) -> String? {
        guard let options = settings.writeOptions else { return settings.problem?.errorDescription }
        let url = fileURL
        // Reopened as a reader, so new restrictions apply at once; the
        // permissions password lifts them again from the bar above the page.
        let openPassword = settings.openPassword.isEmpty ? nil : settings.openPassword
        do {
            try rewriteProtection(options: options, reopeningWith: openPassword, readerPassword: openPassword)
        } catch {
            return error.localizedDescription
        }
        // A remembered open password follows the change.
        if let url, PasswordKeychain.password(for: url) != nil {
            if settings.openPassword.isEmpty {
                PasswordKeychain.remove(for: url)
            } else {
                PasswordKeychain.save(settings.openPassword, for: url)
            }
        }
        return nil
    }

    /// File ▸ Remove Password, after confirming.
    func confirmRemovingPassword() {
        guard isPasswordProtected, let url = fileURL else { return }
        if needsPermissionsPassword, !askToLiftRestrictions() { return }
        let alert = NSAlert()
        alert.messageText = L("Remove the password from “%@”?", displayName)
        alert.informativeText = L("Anyone will be able to open, print, copy and change it.")
        alert.addButton(withTitle: L("Remove Password"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try rewriteProtection(options: PDFPasswordSettings.removalOptions, reopeningWith: nil)
            PasswordKeychain.remove(for: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sets or changes the open password and the restrictions.
struct PasswordSheet: View {
    @EnvironmentObject private var library: ReaderLibrary
    @State private var settings: PDFPasswordSettings
    @State private var openConfirmation = ""
    @State private var permissionsConfirmation = ""
    @State private var problem: String?
    private let isChange: Bool

    init(current: PDFPasswordSettings?, isChange: Bool) {
        _settings = State(initialValue: current ?? PDFPasswordSettings())
        self.isChange = isChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isChange ? L("Change Password") : L("Set Password"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Open password"))
                    .font(.subheadline.weight(.semibold))
                passwordFields($settings.openPassword, confirmation: $openConfirmation)
                Text(L("Leave empty to let anyone open the document."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("Restrict printing, copying and changes"), isOn: $settings.restrictsPermissions)
                    .font(.subheadline.weight(.semibold))
                if settings.restrictsPermissions {
                    passwordFields($settings.permissionsPassword, confirmation: $permissionsConfirmation)
                    Text(L("The permissions password lifts the restrictions. Readers without it may only:"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L("Print"), isOn: $settings.allowsPrinting)
                        Toggle(L("Copy text and images"), isOn: $settings.allowsCopying)
                        Toggle(L("Add annotations and fill in forms"), isOn: $settings.allowsCommenting)
                        Toggle(L("Change content and pages"), isOn: $settings.allowsChanges)
                    }
                    .padding(.leading, 18)
                }
            }

            Text(L("Uses the standard 128-bit PDF encryption (RC4), which every PDF reader supports but which is weak by today’s standards. A forgotten password can’t be recovered."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { library.isEditingPassword = false }
                    .keyboardShortcut(.cancelAction)
                Button(isChange ? L("Change Password") : L("Set Password"), action: apply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .toggleStyle(.checkbox)
    }

    private func passwordFields(_ password: Binding<String>, confirmation: Binding<String>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text(L("Password:"))
                    .gridColumnAlignment(.trailing)
                SecureField("", text: password)
            }
            GridRow {
                Text(L("Verify:"))
                SecureField("", text: confirmation)
            }
        }
    }

    private func apply() {
        if settings.openPassword != openConfirmation {
            problem = L("The open passwords don’t match.")
        } else if settings.restrictsPermissions, settings.permissionsPassword != permissionsConfirmation {
            problem = L("The permissions passwords don’t match.")
        } else if let failure = library.applyPassword(settings) {
            problem = failure
        } else {
            library.isEditingPassword = false
        }
    }
}

/// Above the page while the file's restrictions apply.
struct RestrictionBar: View {
    @EnvironmentObject private var library: ReaderLibrary
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
            Spacer()
            Button(L("Enter Permissions Password…")) { library.askToLiftRestrictions() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.18))
    }
}
