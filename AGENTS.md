# AGENTS

## Project Intent

This repo is a macOS-only Swift 6 editor prototype. Keep the implementation simple, local-first, and easy to iterate on. Prefer incremental architecture over introducing large frameworks.

## Current Architecture

- `Basic Editor/Basic_EditorApp.swift`
  App entry point and command wiring.
- `Basic Editor/ContentView.swift`
  Main `NavigationSplitView`, toolbar, settings popover, and editor composition.
- `Basic Editor/Models/EditorWorkspace.swift`
  App-level state: root folder, open tabs, selected tab, settings, persistence, skin import/export.
- `Basic Editor/Models/EditorModels.swift`
  Core models, editor session snapshot, skin schema models, language inference.
- `Basic Editor/Views/CodeEditorView.swift`
  `NSTextView` bridge for editing, wrapping, and syntax highlighting application.
- `Basic Editor/Views/FileTreeView.swift`
  Sidebar filesystem tree.
- `Basic Editor/Views/TabBarView.swift`
  Horizontal custom tab strip.
- `Basic Editor/Services/SessionStore.swift`
  Session persistence to Application Support.
- `Basic Editor/Services/SkinStore.swift`
  Bundled and user-imported skin loading plus import/export helpers.
- `Basic Editor/Services/SyntaxHighlighting.swift`
  Semantic token theme application and language highlighter implementations.
- `Basic Editor/Skins/*.json`
  Bundled skin definitions.

## Skin System

- Skins are JSON, not hardcoded enums.
- The selected skin is stored by `id`.
- `tokens` is the generic semantic palette.
- `languageOverrides` is where per-language palettes live.
- Future language support should extend semantic token roles first, not fork the file format per language.

## Follow-up Guidance

- If adding Python or other languages, add new `EditorLanguage` cases and highlighters that map into the same semantic roles used by the JSON skin schema.
- Keep settings persistence backward compatible when changing `EditorSessionSnapshot`.
- Prefer bundled JSON examples over embedding default data in Swift, except for minimal fallback safety.
- Avoid replacing `NSTextView` unless there is a concrete blocker; it is the current editing core.
- If modifying import/export, preserve validation before copying imported files into Application Support.

## Known Rough Edges

- `CodeEditorView.swift` still emits Swift 6 warnings around AppKit’s `unowned(unsafe)` `textContainer` and `textStorage` access.
- Syntax highlighting is currently shell-focused; other languages still need actual tokenizers/highlighters.
- The settings popover is functional but intentionally minimal.
