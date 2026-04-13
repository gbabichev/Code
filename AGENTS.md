# AGENTS

## Project Intent

This repo is a macOS-only Swift 6 editor prototype. Keep the implementation simple, local-first, and easy to iterate on. Prefer incremental architecture over introducing large frameworks.

## Current Architecture

- `Code/CodeApp.swift`
  App entry point, scene wiring, focused-window command routing, and menu commands.
- `Code/ContentView.swift`
  Main `NavigationSplitView`, toolbar, redesigned settings popover, sidebar, tab strip, editor composition, search bar, and bottom status bar.
- `Code/Models/AppPreferences.swift`
  Global app preferences shared across windows, including theme, skin, word wrap, sidebar visibility, and editor font settings.
- `Code/Models/EditorWorkspace.swift`
  Per-window workspace state: root folder, file tree, open tabs, selected tab, session persistence, dirty-state helpers used by the sidebar, and window-local reset actions like `Close Folder`.
- `Code/Models/EditorModels.swift`
  Core models, editor session snapshot, tab metadata, manual language overrides, skin schema models, theme derivation, and language inference.
- `Code/Views/CodeEditorView.swift`
  `NSTextView` bridge for editing, wrapping, syntax highlighting, identifier autocomplete, deferred large-file model sync, and the custom gutter container.
- `Code/Views/FileTreeView.swift`
  Sidebar filesystem tree with live dirty indicators on files and folders.
- `Code/Views/TabBarView.swift`
  Horizontal custom tab strip with live dirty indicators per tab.
- `Code/Services/SessionStore.swift`
  Per-window session persistence to Application Support.
- `Code/Services/SkinStore.swift`
  Bundled and user-imported skin loading plus import/export helpers.
- `Code/Services/WorkspaceSessionRegistry.swift`
  Tracks persisted workspace session IDs so relaunch can restore the last window session without re-coupling window state.
- `Code/Services/SyntaxHighlighting.swift`
  Semantic token theme application and language highlighter implementations.
- `Code/Skins/*.json`
  Bundled skin definitions.

## Skin System

- Skins are JSON, not hardcoded enums.
- The selected skin is stored by `id`.
- `tokens` is the generic semantic palette.
- `languageOverrides` is where per-language palettes live.
- Future language support should extend semantic token roles first, not fork the file format per language.

## Editor Behavior Notes

- `EditorWorkspace` is window-local. Open folders, open tabs, selected files, and unsaved buffers should not leak across windows. Global presentation settings belong in `AppPreferences`.
- The editor uses a custom `EditorContainerView` with two sibling views: a `GutterView` on the left and the `NSScrollView`/`NSTextView` editor on the right. Do not reintroduce `NSRulerView` unless there is a specific reason; it previously caused layout and painting issues.
- Word wrap is controlled in `CodeEditorView.Coordinator.configureLayout(isWordWrapEnabled:)`. Wrap mode must change both scroller visibility and text-container sizing; hiding the horizontal scroller alone is not enough.
- The gutter highlights the current line and shows line numbers, including the trailing empty line via `extraLineFragmentRect`. Gutter width is dynamic based on digit count, and wrapped visual fragments should only draw a line number on the first fragment of a logical line. The code area itself currently does not paint a current-line background because earlier approaches interfered with skin rendering.
- Sidebar dirty dots are recursive: file rows are dirty when the matching open tab is dirty, and folder rows are dirty when any descendant file is dirty.
- The bottom status bar is document-scoped. Line count, encoding, line-ending, and language controls reflect the selected tab. Encoding and line-ending changes should update save behavior for that tab, while language selection is a per-tab editor override used for syntax highlighting.
- The status bar also contains file actions for opening the parent folder in Finder and copying the file URL. The language menu should keep `Auto Detect` as the default path and layer explicit overrides on top.
- Closing a dirty tab or intercepting `Cmd+W`/the red stoplight should prompt to save or discard the file. `Cmd+Q` should preserve the workspace session without prompting so the window can be restored as-is on next launch.
- `File > Close Folder` is a per-window reset action. It should clear the current workspace state, remove the root folder and open file tabs for that window, and return the window to a fresh untitled tab without touching global app preferences.
- `EditorWorkspace.attachObserver(to:)` forwards nested `EditorTab.objectWillChange` events through `workspace.objectWillChange.send()`. That is what keeps sidebar and other workspace-driven views live when tab dirty state changes.
- Autocomplete is currently buffer-local and identifier-based through `NSTextView` completion hooks. Keep it focused on variables/functions/symbols already present in the document unless there is a deliberate decision to widen the scope.

## Large File Performance Notes

- Large-file regressions usually come from whole-document work on scroll, open, or typing, not from `NSTextView` itself. Avoid full-buffer scans, full regex passes, `string.count`/line counting, or forced whole-document layout inside scroll, draw, selection, or per-keystroke paths.
- Syntax highlighting for large documents is viewport-first. Initial open should highlight only visible text, scrolling should highlight newly visible text, and any optional offscreen fill should happen incrementally without blocking responsiveness.
- Partial highlighters must honor the requested range. Do not scan the full document when asked to color a small region; multiline constructs may use a bounded contextual scan, but whole-file regex passes will bring back beachballs.
- With syntax highlighting off, typing should not reapply base attributes on every keystroke.
- For large files, `CodeEditorView` treats the `NSTextView` as the hot editing path and defers SwiftUI/model sync until the user pauses. Save paths must flush any pending editor-to-model sync before reading tab content.
- `LineClickableTextView.setFrameSize(_:)` has extra bottom padding logic; keep it idempotent. Non-idempotent size adjustment can create endless layout churn and idle CPU burn.

## Follow-up Guidance

- The project folder is now `Code`, but some internal symbols and persistence locations still use the legacy `Basic Editor` name. Treat those as compatibility-sensitive until they are deliberately migrated.
- Untitled tabs are a first-class flow. Avoid reintroducing assumptions that every tab has a file URL.
- If adding Python or other languages, add new `EditorLanguage` cases and highlighters that map into the same semantic roles used by the JSON skin schema.
- Keep settings persistence backward compatible when changing `EditorSessionSnapshot`.
- Prefer bundled JSON examples over embedding default data in Swift, except for minimal fallback safety.
- Avoid replacing `NSTextView` unless there is a concrete blocker; it is the current editing core.
- If modifying import/export, preserve validation before copying imported files into Application Support.

## Known Rough Edges

- Syntax highlighting is currently shell-focused; other languages still need actual tokenizers/highlighters.
- The settings popover is now more presentation-focused, with grouped card-style sections and a live font preview, but it is still backed by the same `AppPreferences` model.
- Current-line emphasis is gutter-only. If full-width current-line highlighting is reintroduced, do it with a dedicated layout/background approach that does not wash out the selected skin.
