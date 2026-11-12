# NiuPDF

A small native macOS PDF reader built with SwiftUI and PDFKit. It takes inspiration from Skim's reading workflow and PageFlow's native SwiftUI/PDFKit approach; no source code from either project is included.

## Features

The complete, current feature list (in Chinese) is in [docs/FEATURES.md](docs/FEATURES.md). Highlights:

- Open several PDFs at once with `⌘O`, by dragging them into the window or from Finder; each opens in its own tab, and tabs can be dragged out into windows
- A start page with recent files; each file reopens at its own page and zoom
- Standard shortcuts, following macOS Preview: `⌘W` close tab, `⌘T`/`⌘N` new tab/window, `⌘P` print, `⌥⌘1`–`4` sidebar, `⌘=`/`⌘-`/`⌘0`/`⌘9` zoom, `⌃⌘1`–`4` page layout, `⌥⌘↑`/`⌥⌘↓` pages, `⌃⌘H`/`U`/`S`… annotation tools
- Navigate pages from the thumbnail sidebar or page number field
- Manage pages: select thumbnails (⌘-click, ⇧-click), drag to reorder, rotate (`⌘L`/`⌘R`), delete, insert blank pages or pages from other PDFs (also by dropping PDFs on the thumbnails), and extract pages to a new PDF; all undoable
- Search document text and move through matches
- Zoom in and out
- Highlight, underline and strike out selected text; overlapping markup merges, and toggling marked text erases just that part
- Click markup to change its color, write a note or delete it; "Add Note" attaches a note to the highlighted text
- Notes show as sharp, constant-size icons with hover preview
- Annotate tab: expands a tool row with highlight, underline, strikethrough, freehand drawing, text boxes, rectangles, ellipses, arrows and sticky notes; tools stay active until chosen again or Esc
- Edit annotations: click to select (⇧-click for several), drag handles to resize, drag or use the arrow keys to move, `⌘C`/`⌘X`/`⌘V`/`⌘D` to copy, cut, paste (also onto another page or document) and duplicate, Delete to remove; all undoable
- Line width for drawings and shapes, and font family and size for text boxes, from the tool row or by clicking an annotation
- Export tab: save a PDF copy with annotations kept or flattened, or export pages as PNG or JPEG at 72, 150 or 300 dpi
- Settings (`⌘,`) to choose the interface language: follow the system, English or Simplified Chinese
- Browse, jump to and delete annotations from the annotation list sidebar
- Undo and redo annotation edits with `⌘Z` / `⇧⌘Z`
- Open password-protected PDFs
- Annotations are saved automatically a moment after each change, and when switching apps, opening another file or quitting; `⌘S` saves at once, and autosave can be turned off in Settings

## Languages

The interface follows the macOS language setting and is fully English or fully Simplified Chinese, including PDFKit's own menu items. UI strings live in `Sources/*/Resources/{en,zh-Hans}.lproj/Localizable.strings`; keys are the English text, and every key must exist in both tables.

## Build and run

Requires macOS 13 or later and Xcode 27. Open `Paperplane.xcodeproj`, select the `Paperplane` scheme, and run it. The Xcode target builds a sandboxed macOS app with access to files explicitly selected by the user.

For command-line development, `swift run NiuPDF` builds the Swift package executable. That executable is not the App Store sandboxed app. Run the Xcode target when checking sandbox behavior or preparing an app bundle.

The current bundle identifier, `app.paperplane.reader`, is a development placeholder. Set the identifier to one registered by the publisher before distribution and configure the matching signing team in Xcode.

The project uses Apple's built-in PDFKit framework and contains no third-party runtime dependencies.
