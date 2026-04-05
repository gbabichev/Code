# Basic Editor

Minimal macOS-only SwiftUI/AppKit file editor in Swift 6.

## Current Scope

- `NavigationSplitView` shell with filesystem sidebar
- Multiple open file tabs
- Draft/session restore across app relaunch
- AppKit-backed text editor with shell-oriented syntax highlighting
- JSON-backed syntax skin system with import/export

## Skin Schema

Skins are JSON files loaded from:

- Bundled app resources: `Basic Editor/Skins/*.json`
- User skins: `~/Library/Application Support/Basic Editor/Skins/*.json`

The selected skin is persisted by `id`, so bundled and imported skins use the same path.

### Schema

```json
{
  "schemaVersion": 1,
  "id": "forest",
  "name": "Forest",
  "editor": {
    "background": { "light": "#F2F5E6FF", "dark": "#171C18FF" },
    "foreground": { "light": "#2B3328FF", "dark": "#D9E3D2FF" }
  },
  "tokens": {
    "keyword":  { "light": "#007768FF", "dark": "#88F2DDFF" },
    "builtin":  { "light": "#2759B8FF", "dark": "#75B8FFFF" },
    "variable": { "light": "#A75A0BFF", "dark": "#F5C467FF" },
    "string":   { "light": "#2F7A1FFF", "dark": "#A8E882FF" },
    "comment":  { "light": "#6A7A67FF", "dark": "#78907BFF" },
    "command":  { "light": "#6A2FB0FF", "dark": "#D5A3FFFF" }
  },
  "languageOverrides": {
    "shell": {
      "keyword":  { "light": "#007768FF", "dark": "#88F2DDFF" },
      "builtin":  { "light": "#2759B8FF", "dark": "#75B8FFFF" },
      "variable": { "light": "#A75A0BFF", "dark": "#F5C467FF" },
      "string":   { "light": "#2F7A1FFF", "dark": "#A8E882FF" },
      "comment":  { "light": "#6A7A67FF", "dark": "#78907BFF" },
      "command":  { "light": "#6A2FB0FF", "dark": "#D5A3FFFF" }
    }
  }
}
```

### Notes

- Colors are hex strings in `#RRGGBB` or `#RRGGBBAA` format.
- `tokens` is the generic fallback palette.
- `languageOverrides` is keyed by language id like `shell`.
- The schema is intentionally semantic rather than regex-specific.

That matters for future languages. The JSON should describe roles like `keyword`, `string`, `comment`, `builtin`, `variable`, `command`, and later additional roles such as `type`, `number`, `operator`, `function`, `property`, `decorator`, or `attribute` can be added without redesigning the file format. Language-specific highlighters should map their parser/regex output onto these shared semantic roles.

## Import / Export

- Import from the settings popover copies a validated skin JSON into the app support skins folder.
- Export writes the currently selected skin back out as JSON.

## Build

Example local build without signing:

```sh
xcodebuild -project 'Basic Editor.xcodeproj' -scheme 'Basic Editor' -configuration Debug -sdk macosx -derivedDataPath '.derivedData' CODE_SIGNING_ALLOWED=NO build
```
