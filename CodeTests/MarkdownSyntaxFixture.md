# Markdown Syntax Fixture

This file exercises common Markdown syntax, inline HTML, quote-like characters,
links, images, code fences, task lists, and tables.

## Inline Text

Plain text with `inline code`, **strong text**, *emphasis*, ***strong emphasis***,
~~strikethrough~~, [a relative link](../README.md), and [an external link](https://example.com).

Straight quotes: `'single'`, `"double"`, `` `backticks` ``, and escaped quotes:
`\"`, `\'`, and `` \` ``.

Inline shell sample: `printf '%s\n' "$HOME"`.
Inline PowerShell sample: `"Name=$Name"; 'literal $Name'; Write-Output \`"quoted\`"`.

## Lists

- Unordered item
- Item with nested text
  - Nested item
  - Nested item with `code`
- Item with HTML: <span title="inline title">span content</span>

1. Ordered item
2. Ordered item with a [link](../docs/icon.png)
3. Ordered item with emphasis and code

- [x] Completed task
- [ ] Pending task
- [ ] Task with `inline code`

## Block Quotes

> Single-line quote.
> Continued quote with **formatting** and `code`.

> Nested quote:
>
> > Inner quote with a link to [README](../README.md).

## Inline HTML

<p align="center">
  <img src="../docs/icon.png" alt="Fixture image" width="96" height="96">
</p>

<div align="right" title="right aligned block">
  Right-aligned HTML block with <strong>strong</strong> text.
</div>

<details>
<summary>Details summary</summary>

Details body with Markdown-style punctuation and HTML content.

</details>

## Table

| Syntax | Example | Notes |
| --- | ---: | :--- |
| Single quotes | `'literal $HOME'` | No interpolation |
| Double quotes | `"expanded $HOME"` | Interpolation |
| Backticks | `` `inline code` `` | Inline code |
| HTML | `<p align="center">` | Sanitized attributes |

## Shell Fence

```sh
#!/usr/bin/env bash
set -euo pipefail

single='literal $HOME'
double="expanded ${HOME:-unknown}"
ansi=$'line one\nline two'
escaped="quote: \" dollar: \$ backtick: \`"

cat <<'EOF'
single quoted heredoc
$HOME remains literal
EOF

for value in "$single" "$double" "$ansi" "$escaped"; do
  printf '%s\n' "$value"
done
```

## PowerShell Fence

```powershell
$single = 'literal $HOME'
$double = "expanded user=$env:USER"
$escaped = "quote: `" dollar: `$ backtick: ``"
$here = @'
Single-quoted here-string.
$Name stays literal.
'@

if ($double -match 'expanded') {
    Write-Output "matched: $($Matches[0])"
}
```

## JSON Fence

```json
{
  "name": "Markdown Syntax Fixture",
  "quotes": ["single", "double", "backtick"],
  "enabled": true,
  "count": 3
}
```

## Edge Cases

Horizontal rule:

---

Autolink: <https://example.com/path?query=value#fragment>

Email autolink: <test@example.com>

Escaped Markdown markers: \*not emphasis\*, \`not code\`, \[not a link\].
