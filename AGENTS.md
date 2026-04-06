# AGENTS

## Project Intent

This repo is a macOS-only Swift 6 editor prototype. Keep the implementation simple, local-first, and easy to iterate on. Prefer incremental architecture over introducing large frameworks.

## Current Architecture

- `Code/CodeApp.swift`
  App entry point and command wiring, including menu commands like `View > Word Wrap`.
- `Code/ContentView.swift`
  Main `NavigationSplitView`, toolbar, settings popover, sidebar, tab strip, and editor composition.
- `Code/Models/EditorWorkspace.swift`
  App-level state: root folder, file tree, open tabs, selected tab, settings, persistence, skin import/export, and dirty-state helpers used by the sidebar.
- `Code/Models/EditorModels.swift`
  Core models, editor session snapshot, skin schema models, theme derivation, and language inference.
- `Code/Views/CodeEditorView.swift`
  `NSTextView` bridge for editing, wrapping, syntax highlighting, and the custom gutter container.
- `Code/Views/FileTreeView.swift`
  Sidebar filesystem tree with live dirty indicators on files and folders.
- `Code/Views/TabBarView.swift`
  Horizontal custom tab strip with live dirty indicators per tab.
- `Code/Services/SessionStore.swift`
  Session persistence to Application Support.
- `Code/Services/SkinStore.swift`
  Bundled and user-imported skin loading plus import/export helpers.
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

- The editor uses a custom `EditorContainerView` with two sibling views: a fixed-width `GutterView` on the left and the `NSScrollView`/`NSTextView` editor on the right. Do not reintroduce `NSRulerView` unless there is a specific reason; it previously caused layout and painting issues.
- Word wrap is controlled in `CodeEditorView.Coordinator.configureLayout(isWordWrapEnabled:)`. Wrap mode must change both scroller visibility and text-container sizing; hiding the horizontal scroller alone is not enough.
- The gutter highlights the current line and shows line numbers. The code area itself currently does not paint a current-line background because earlier approaches interfered with skin rendering.
- Sidebar dirty dots are recursive: file rows are dirty when the matching open tab is dirty, and folder rows are dirty when any descendant file is dirty.
- `EditorWorkspace.attachObserver(to:)` forwards nested `EditorTab.objectWillChange` events through `workspace.objectWillChange.send()`. That is what keeps sidebar and other workspace-driven views live when tab dirty state changes.

## Follow-up Guidance

- The project folder is now `Code`, but some internal symbols and persistence locations still use the legacy `Basic Editor` name. Treat those as compatibility-sensitive until they are deliberately migrated.
- If adding Python or other languages, add new `EditorLanguage` cases and highlighters that map into the same semantic roles used by the JSON skin schema.
- Keep settings persistence backward compatible when changing `EditorSessionSnapshot`.
- Prefer bundled JSON examples over embedding default data in Swift, except for minimal fallback safety.
- Avoid replacing `NSTextView` unless there is a concrete blocker; it is the current editing core.
- If modifying import/export, preserve validation before copying imported files into Application Support.

## Known Rough Edges

- Syntax highlighting is currently shell-focused; other languages still need actual tokenizers/highlighters.
- The settings popover is functional but intentionally minimal.
- Current-line emphasis is gutter-only. If full-width current-line highlighting is reintroduced, do it with a dedicated layout/background approach that does not wash out the selected skin.
