import Foundation
import PDFKit

/// A document's passwords and what a reader without the permissions password
/// may do, turned into PDFKit write options.
///
/// PDFKit writes the PDF standard security handler, revision 3 (128-bit RC4),
/// whatever is asked. It encrypts only with an owner password: an open
/// password alone would be written unencrypted, so it doubles as the owner
/// password when nothing is restricted.
public struct PDFPasswordSettings: Equatable {
    /// Needed to open the document; empty for none.
    public var openPassword: String
    /// Restrictions apply only with a permissions password.
    public var restrictsPermissions: Bool
    /// Lifts the restrictions; must differ from the open password.
    public var permissionsPassword: String
    public var allowsPrinting: Bool
    public var allowsCopying: Bool
    public var allowsCommenting: Bool
    /// Changes to the content and to pages: insert, delete, rotate, reorder.
    public var allowsChanges: Bool

    public init(
        openPassword: String = "",
        restrictsPermissions: Bool = false,
        permissionsPassword: String = "",
        allowsPrinting: Bool = true,
        allowsCopying: Bool = true,
        allowsCommenting: Bool = false,
        allowsChanges: Bool = false
    ) {
        self.openPassword = openPassword
        self.restrictsPermissions = restrictsPermissions
        self.permissionsPassword = permissionsPassword
        self.allowsPrinting = allowsPrinting
        self.allowsCopying = allowsCopying
        self.allowsCommenting = allowsCommenting
        self.allowsChanges = allowsChanges
    }

    public enum Problem: LocalizedError, Equatable {
        case nothingToProtect
        case missingPermissionsPassword
        case samePasswords

        public var errorDescription: String? {
            switch self {
            case .nothingToProtect:
                return L("Enter an open password, or restrict what readers may do.")
            case .missingPermissionsPassword:
                return L("Restrictions need a permissions password.")
            case .samePasswords:
                return L("The permissions password must differ from the open password, or anyone who can open the document could lift the restrictions.")
            }
        }
    }

    /// The first problem that keeps these settings from being written, if any.
    public var problem: Problem? {
        if restrictsPermissions {
            if permissionsPassword.isEmpty { return .missingPermissionsPassword }
            if permissionsPassword == openPassword { return .samePasswords }
            return nil
        }
        return openPassword.isEmpty ? .nothingToProtect : nil
    }

    /// PDFKit permission bits; accessibility extraction is always allowed.
    public var accessPermissions: UInt {
        var permissions = PDFAccessPermissions.allowsContentAccessibility.rawValue
        if allowsPrinting {
            permissions |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue | PDFAccessPermissions.allowsHighQualityPrinting.rawValue
        }
        if allowsCopying { permissions |= PDFAccessPermissions.allowsContentCopying.rawValue }
        if allowsCommenting {
            permissions |= PDFAccessPermissions.allowsCommenting.rawValue | PDFAccessPermissions.allowsFormFieldEntry.rawValue
        }
        if allowsChanges {
            permissions |= PDFAccessPermissions.allowsDocumentChanges.rawValue | PDFAccessPermissions.allowsDocumentAssembly.rawValue
        }
        return permissions
    }

    /// Options for `PDFDocument.write(to:withOptions:)`; nil while `problem` is set.
    public var writeOptions: [PDFDocumentWriteOption: Any]? {
        guard problem == nil else { return nil }
        guard restrictsPermissions else {
            return [.userPasswordOption: openPassword, .ownerPasswordOption: openPassword]
        }
        var options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: permissionsPassword,
            .accessPermissionsOption: accessPermissions
        ]
        if !openPassword.isEmpty { options[.userPasswordOption] = openPassword }
        return options
    }

    /// Options that write the document without passwords or restrictions.
    /// PDFKit keeps an encryption dictionary with empty passwords, which every
    /// reader opens without asking; rebuilding the file to drop it entirely
    /// would lose its outline and other document-level data.
    public static let removalOptions: [PDFDocumentWriteOption: Any] = [.userPasswordOption: "", .ownerPasswordOption: ""]
}
