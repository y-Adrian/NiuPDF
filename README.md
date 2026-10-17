# Paperplane

A small native macOS PDF reader built with SwiftUI and PDFKit. It takes inspiration from Skim's reading workflow and PageFlow's native SwiftUI/PDFKit approach; no source code from either project is included.

## Features

- Open PDFs with `⌘O` or drag a file into the window
- Navigate pages from the thumbnail sidebar or page number field
- Search document text and move through matches
- Zoom in and out
- Highlight selected text
- Save PDF annotations with `⌘S`

## Run

Requires macOS 13 or later and the Swift command-line tools. From this folder, run `swift run`.

The project uses Apple's built-in PDFKit framework and contains no third-party runtime dependencies.
