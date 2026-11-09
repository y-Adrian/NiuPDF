# Paperplane

A small native macOS PDF reader built with SwiftUI and PDFKit. It takes inspiration from Skim's reading workflow and PageFlow's native SwiftUI/PDFKit approach; no source code from either project is included.

## Features

- Open PDFs with `⌘O` or drag a file into the window
- Navigate pages from the thumbnail sidebar or page number field
- Search document text and move through matches
- Zoom in and out
- Highlight, underline and strike out selected text; overlapping markup merges, and toggling marked text erases just that part
- Click markup to change its color, write a note or delete it; "Add Note" attaches a note to the highlighted text
- Notes show as sharp, constant-size icons with hover preview
- Browse, jump to and delete annotations from the annotation list sidebar
- Undo and redo annotation edits with `⌘Z` / `⇧⌘Z`
- Open password-protected PDFs
- Save PDF annotations with `⌘S`; unsaved changes are confirmed before opening another file or quitting

## Languages

The interface follows the macOS language setting and is fully English or fully Simplified Chinese, including PDFKit's own menu items. UI strings live in `Sources/*/Resources/{en,zh-Hans}.lproj/Localizable.strings`; keys are the English text, and every key must exist in both tables.

## Build and run

Requires macOS 13 or later and Xcode 27. Open `Paperplane.xcodeproj`, select the `Paperplane` scheme, and run it. The Xcode target builds a sandboxed macOS app with access to files explicitly selected by the user.

For command-line development, `swift run` still builds the Swift package executable. That executable is not the App Store sandboxed app. Run the Xcode target when checking sandbox behavior or preparing an app bundle.

The current bundle identifier, `app.paperplane.reader`, is a development placeholder. Set the identifier to one registered by the publisher before distribution and configure the matching signing team in Xcode.

The project uses Apple's built-in PDFKit framework and contains no third-party runtime dependencies.
