//
//  MarkdownPreviewView.swift
//  Code
//

import AppKit
import Foundation
import SwiftUI
import WebKit

struct MarkdownPreviewView: View {
    private static let maximumRenderedUTF16Length = 1_000_000

    let markdown: String
    let baseURL: URL?
    let skin: SkinDefinition
    let editorFont: NSFont

    private var html: String {
        MarkdownHTMLRenderer.render(
            markdown: markdown,
            baseURL: baseURL,
            skin: skin,
            editorFont: editorFont,
            maximumRenderedUTF16Length: Self.maximumRenderedUTF16Length
        )
    }

    var body: some View {
        MarkdownPreviewWebView(html: html, baseURL: baseURL)
            .background(Color(nsColor: skin.editor.background.resolveColor()))
    }
}

private struct MarkdownPreviewWebView: NSViewRepresentable {
    private static let legacyNavigationTypeActionKey = "WebActionNavigationType"
    private static let legacyLinkClickedNavigationType = 0

    let html: String
    let baseURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        guard let webView = legacyWebView() else {
            return NSView(frame: .zero)
        }
        if let preferences = legacyWebPreferences() {
            webView.setValue(preferences, forKey: "preferences")
        }
        webView.setValue(false, forKey: "drawsBackground")
        webView.setValue(false, forKey: "shouldCloseWithWindow")
        webView.setValue(context.coordinator, forKey: "frameLoadDelegate")
        webView.setValue(context.coordinator, forKey: "policyDelegate")
        context.coordinator.updateObservedScrollView(in: webView)
        return webView
    }

    func updateNSView(_ webView: NSView, context: Context) {
        guard context.coordinator.loadedHTML != html
                || context.coordinator.loadedBaseURL != baseURL else { return }

        context.coordinator.prepareForReload(in: webView)
        context.coordinator.loadedHTML = html
        context.coordinator.loadedBaseURL = baseURL
        context.coordinator.loadHTML(html, baseURL: baseURL, in: webView)
    }

    private func legacyWebView() -> NSView? {
        guard let webViewClass = NSClassFromString("WebView") as? NSView.Type else {
            return nil
        }
        return webViewClass.init(frame: .zero)
    }

    private func legacyWebPreferences() -> NSObject? {
        guard let preferencesClass = NSClassFromString("WebPreferences") as? NSObject.Type else {
            return nil
        }

        let preferences = preferencesClass.init()
        preferences.setValue(false, forKey: "javaScriptEnabled")
        preferences.setValue(false, forKey: "javaScriptCanOpenWindowsAutomatically")
        preferences.setValue(false, forKey: "plugInsEnabled")
        return preferences
    }

    final class Coordinator: NSObject {
        var loadedHTML = ""
        var loadedBaseURL: URL?
        private var observedClipView: NSClipView?
        private var clipViewBoundsObserver: NSObjectProtocol?
        private var lastKnownScrollState: PreviewScrollState?
        private var pendingScrollState: PreviewScrollState?
        private var scrollRestoreGeneration = 0
        private var isReloadingPreview = false

        deinit {
            MainActor.assumeIsolated {
                if let clipViewBoundsObserver {
                    NotificationCenter.default.removeObserver(clipViewBoundsObserver)
                }
            }
        }

        func loadHTML(_ html: String, baseURL: URL?, in webView: NSView) {
            guard let mainFrame = mainFrame(in: webView) else { return }
            unsafe _ = mainFrame.perform(
                NSSelectorFromString("loadHTMLString:baseURL:"),
                with: html,
                with: baseURL as NSURL?
            )
        }

        @objc(webView:decidePolicyForNavigationAction:request:frame:decisionListener:)
        func webView(
            _ webView: AnyObject,
            decidePolicyForNavigationAction actionInformation: NSDictionary,
            request: NSURLRequest,
            frame: AnyObject,
            decisionListener listener: AnyObject
        ) {
            guard let url = request.url else {
                performPolicyAction("use", on: listener)
                return
            }

            if url.scheme?.lowercased() == "javascript" {
                performPolicyAction("ignore", on: listener)
                return
            }

            let navigationType = actionInformation[MarkdownPreviewWebView.legacyNavigationTypeActionKey] as? NSNumber
            if navigationType?.intValue == MarkdownPreviewWebView.legacyLinkClickedNavigationType {
                if MarkdownHTMLSanitizer.isSafeLinkURL(url.absoluteString) {
                    NSWorkspace.shared.open(url)
                }
                performPolicyAction("ignore", on: listener)
                return
            }

            performPolicyAction("use", on: listener)
        }

        @objc(webView:didFinishLoadForFrame:)
        func webView(_ sender: AnyObject, didFinishLoadFor frame: AnyObject) {
            guard let webView = sender as? NSView,
                  let mainFrame = mainFrame(in: webView),
                  mainFrame === frame else { return }
            updateObservedScrollView(in: webView)
            restorePendingScrollState(in: webView)
        }

        func prepareForReload(in webView: NSView) {
            updateObservedScrollView(in: webView)
            if let currentScrollState = captureScrollState(in: webView) {
                lastKnownScrollState = currentScrollState
            }
            pendingScrollState = lastKnownScrollState
            isReloadingPreview = true
        }

        func updateObservedScrollView(in webView: NSView) {
            guard let scrollView = scrollView(in: webView) else { return }
            let clipView = scrollView.contentView
            guard observedClipView !== clipView else { return }

            if let clipViewBoundsObserver {
                NotificationCenter.default.removeObserver(clipViewBoundsObserver)
            }

            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            clipViewBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak webView] _ in
                DispatchQueue.main.async {
                    guard let self,
                          let webView,
                          !self.isReloadingPreview,
                          let scrollState = self.captureScrollState(in: webView) else { return }
                    self.lastKnownScrollState = scrollState
                }
            }
        }

        private func captureScrollState(in webView: NSView) -> PreviewScrollState? {
            guard let scrollView = scrollView(in: webView) else { return nil }
            let visibleRect = scrollView.contentView.bounds
            let documentSize = scrollView.documentView?.bounds.size ?? .zero
            let maxOffset = NSPoint(
                x: max(documentSize.width - visibleRect.width, 0),
                y: max(documentSize.height - visibleRect.height, 0)
            )

            return PreviewScrollState(
                offset: NSPoint(
                    x: min(max(visibleRect.origin.x, 0), maxOffset.x),
                    y: min(max(visibleRect.origin.y, 0), maxOffset.y)
                ),
                maxOffset: maxOffset
            )
        }

        private func restorePendingScrollState(in webView: NSView) {
            guard let state = pendingScrollState else {
                isReloadingPreview = false
                return
            }

            scrollRestoreGeneration += 1
            let generation = scrollRestoreGeneration
            restoreScrollState(state, in: webView)

            for delay in [0.03, 0.1, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self,
                          let webView,
                          self.scrollRestoreGeneration == generation else { return }
                    self.restoreScrollState(state, in: webView)
                    if delay == 0.25 {
                        self.isReloadingPreview = false
                        self.lastKnownScrollState = self.captureScrollState(in: webView)
                    }
                }
            }
        }

        private func restoreScrollState(_ state: PreviewScrollState, in webView: NSView) {
            guard let scrollView = scrollView(in: webView),
                  let documentView = scrollView.documentView else { return }

            let visibleRect = scrollView.contentView.bounds
            let documentSize = documentView.bounds.size
            let maxOffset = NSPoint(
                x: max(documentSize.width - visibleRect.width, 0),
                y: max(documentSize.height - visibleRect.height, 0)
            )
            let offset = NSPoint(
                x: restoredOffset(from: state.offset.x, oldMax: state.maxOffset.x, newMax: maxOffset.x),
                y: restoredOffset(from: state.offset.y, oldMax: state.maxOffset.y, newMax: maxOffset.y)
            )

            scrollView.contentView.scroll(to: offset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func restoredOffset(from offset: CGFloat, oldMax: CGFloat, newMax: CGFloat) -> CGFloat {
            guard newMax > 0 else { return 0 }
            guard oldMax > 0 else { return min(max(offset, 0), newMax) }

            let relativeOffset = newMax * min(max(offset / oldMax, 0), 1)
            let preferredOffset = abs(newMax - oldMax) < 80 ? offset : relativeOffset
            return min(max(preferredOffset, 0), newMax)
        }

        private func scrollView(in webView: NSView) -> NSScrollView? {
            if let frameView = mainFrame(in: webView)?.value(forKey: "frameView") as? NSObject,
               let documentView = frameView.value(forKey: "documentView") as? NSView,
               let scrollView = documentView.enclosingScrollView {
                return scrollView
            }

            return firstScrollView(in: webView)
        }

        private func mainFrame(in webView: NSView) -> AnyObject? {
            guard webView.responds(to: NSSelectorFromString("mainFrame")) else { return nil }
            return webView.value(forKey: "mainFrame") as AnyObject?
        }

        private func performPolicyAction(_ action: String, on listener: AnyObject) {
            unsafe _ = listener.perform(NSSelectorFromString(action))
        }

        private func firstScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            for subview in view.subviews {
                if let scrollView = firstScrollView(in: subview) {
                    return scrollView
                }
            }
            return nil
        }
    }

    private struct PreviewScrollState {
        let offset: NSPoint
        let maxOffset: NSPoint
    }
}

private enum MarkdownHTMLRenderer {
    static func render(
        markdown: String,
        baseURL: URL?,
        skin: SkinDefinition,
        editorFont: NSFont,
        maximumRenderedUTF16Length: Int
    ) -> String {
        let background = cssColor(skin.editor.background.resolveColor())
        let foreground = cssColor(skin.editor.foreground.resolveColor())
        let muted = cssRGBA(skin.editor.foreground.resolveColor(), alpha: 0.68)
        let border = cssRGBA(skin.editor.foreground.resolveColor(), alpha: 0.14)
        let fill = cssRGBA(skin.editor.foreground.resolveColor(), alpha: 0.055)
        let codeFill = cssRGBA(skin.editor.foreground.resolveColor(), alpha: 0.08)
        let linkColor = cssColor(skin.tokens.builtin.resolveColor())
        let fontSize = max(editorFont.pointSize + 1, 13)
        let codeFontName = cssString(editorFont.fontName)
        let bodyHTML: String

        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyHTML = unavailableHTML(title: "No Preview", message: "This Markdown file is empty.")
        } else if markdown.utf16.count > maximumRenderedUTF16Length {
            bodyHTML = unavailableHTML(title: "Preview Paused", message: "This Markdown file is too large to render live.")
        } else {
            bodyHTML = MarkdownPreviewParser.parse(markdown)
                .map { renderBlock($0, baseURL: baseURL) }
                .joined(separator: "\n")
        }

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: http: https: data:; style-src 'unsafe-inline'; script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';">
        <style>
        :root {
            color-scheme: light dark;
            --background: \(background);
            --foreground: \(foreground);
            --muted: \(muted);
            --border: \(border);
            --fill: \(fill);
            --code-fill: \(codeFill);
            --link: \(linkColor);
            --code-font: \(codeFontName), ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        }
        * { box-sizing: border-box; }
        html, body {
            margin: 0;
            min-height: 100%;
            background: var(--background);
            color: var(--foreground);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            font-size: \(decimal(fontSize, places: 1))px;
            line-height: 1.58;
        }
        main {
            padding: 24px 28px 40px;
            width: 100%;
        }
        h1, h2, h3, h4, h5, h6 {
            margin: 0.25em 0 0.55em;
            line-height: 1.2;
            font-weight: 650;
            letter-spacing: 0;
        }
        h1 { font-size: 2.05em; }
        h2 { font-size: 1.6em; border-bottom: 1px solid var(--border); padding-bottom: 0.28em; }
        h3 { font-size: 1.32em; }
        h4 { font-size: 1.15em; }
        h5, h6 { font-size: 1em; color: var(--muted); }
        p, ul, ol, blockquote, pre, table, figure, details {
            margin-top: 0;
            margin-bottom: 1em;
        }
        p { overflow-wrap: anywhere; }
        [align="left"] { text-align: left; }
        [align="right"] { text-align: right; }
        [align="center"] { text-align: center; }
        [align="justify"] { text-align: justify; }
        [align="start"] { text-align: start; }
        [align="end"] { text-align: end; }
        a {
            color: var(--link);
            text-decoration-thickness: 0.08em;
            text-underline-offset: 0.16em;
        }
        ul, ol { padding-left: 1.55em; }
        li > ul, li > ol {
            margin-top: 0.22em;
            margin-bottom: 0.28em;
        }
        ul ul, ul ol, ol ul, ol ol { padding-left: 1.45em; }
        li { margin: 0.22em 0; }
        li.task-list-item {
            list-style: none;
        }
        li.task-list-item > input[type="checkbox"] {
            margin: 0 0.45em 0 -1.35em;
            pointer-events: none;
        }
        blockquote {
            color: var(--muted);
            border-left: 3px solid var(--border);
            padding: 0.65em 0.85em;
            background: var(--fill);
            border-radius: 6px;
        }
        pre {
            overflow-x: auto;
            padding: 0.85em;
            background: var(--fill);
            border: 1px solid var(--border);
            border-radius: 6px;
        }
        code, kbd {
            font-family: var(--code-font);
            font-size: 0.92em;
            background: var(--code-fill);
            border-radius: 4px;
            padding: 0.12em 0.28em;
        }
        pre code {
            display: block;
            padding: 0;
            background: transparent;
            border-radius: 0;
            white-space: pre;
        }
        img {
            max-width: 100%;
            height: auto;
            border-radius: 4px;
            vertical-align: middle;
        }
        figure { margin-left: 0; margin-right: 0; }
        figcaption {
            margin-top: 0.35em;
            color: var(--muted);
            font-size: 0.88em;
        }
        table {
            border-collapse: collapse;
            width: 100%;
            display: block;
            overflow-x: auto;
        }
        th, td {
            border: 1px solid var(--border);
            padding: 0.45em 0.65em;
            text-align: left;
            vertical-align: top;
        }
        th { background: var(--fill); font-weight: 650; }
        hr {
            border: 0;
            border-top: 1px solid var(--border);
            margin: 1.2em 0;
        }
        .empty-state {
            min-height: 260px;
            display: grid;
            place-content: center;
            text-align: center;
            color: var(--muted);
        }
        .empty-state strong {
            display: block;
            color: var(--foreground);
            font-size: 1.05em;
            margin-bottom: 0.3em;
        }
        </style>
        </head>
        <body>
        <main>
        \(bodyHTML)
        </main>
        </body>
        </html>
        """
    }

    private static func renderBlock(_ block: MarkdownPreviewBlock, baseURL: URL?) -> String {
        switch block {
        case let .heading(level, text):
            let clampedLevel = min(max(level, 1), 6)
            return "<h\(clampedLevel)>\(MarkdownInlineRenderer.render(text, baseURL: baseURL))</h\(clampedLevel)>"
        case let .paragraph(text):
            return "<p>\(MarkdownInlineRenderer.render(text, baseURL: baseURL))</p>"
        case let .unorderedList(items):
            return renderList(items: items, ordered: false, baseURL: baseURL)
        case let .orderedList(items):
            return renderList(items: items, ordered: true, baseURL: baseURL)
        case let .blockquote(text):
            return "<blockquote>\(MarkdownInlineRenderer.render(text, baseURL: baseURL))</blockquote>"
        case let .table(table):
            return renderTable(table, baseURL: baseURL)
        case let .code(language, text):
            let classAttribute = language
                .flatMap { sanitizedClassName("language-\($0)") }
                .map { " class=\"\($0)\"" }
                ?? ""
            return "<pre><code\(classAttribute)>\(escapeHTML(text))</code></pre>"
        case let .image(image):
            guard let source = MarkdownHTMLSanitizer.sanitizedURLString(
                image.target,
                allowDataImages: true,
                baseURL: baseURL
            ) else {
                return unavailableHTML(title: "Image Hidden", message: image.alt.isEmpty ? image.target : image.alt)
            }
            let alt = escapeHTMLAttribute(image.alt)
            let caption = image.alt.isEmpty
                ? ""
                : "<figcaption>\(MarkdownInlineRenderer.render(image.alt, baseURL: baseURL))</figcaption>"
            return "<figure><img src=\"\(escapeHTMLAttribute(source))\" alt=\"\(alt)\">\(caption)</figure>"
        case .rule:
            return "<hr>"
        }
    }

    private static func renderList(items: [MarkdownPreviewListItem], ordered: Bool, baseURL: URL?) -> String {
        let tag = ordered ? "ol" : "ul"
        let itemHTML = items.map { item in
            let checkbox = item.checklistState.map { state in
                state == .checked
                    ? "<input type=\"checkbox\" checked disabled>"
                    : "<input type=\"checkbox\" disabled>"
            } ?? ""
            let classAttribute = item.checklistState == nil ? "" : " class=\"task-list-item\""
            let childHTML = item.children.map { childList in
                renderList(items: childList.items, ordered: childList.ordered, baseURL: baseURL)
            }.joined()
            return "<li\(classAttribute)>\(checkbox)\(MarkdownInlineRenderer.render(item.text, baseURL: baseURL))\(childHTML)</li>"
        }.joined()
        return "<\(tag)>\(itemHTML)</\(tag)>"
    }

    private static func renderTable(_ table: MarkdownPreviewTable, baseURL: URL?) -> String {
        let headerHTML = table.header.enumerated().map { index, cell in
            "<th\(alignmentAttribute(table.alignments[index]))>\(MarkdownInlineRenderer.render(cell, baseURL: baseURL))</th>"
        }.joined()
        let rowsHTML = table.rows.map { row in
            let cellsHTML = row.enumerated().map { index, cell in
                "<td\(alignmentAttribute(table.alignments[index]))>\(MarkdownInlineRenderer.render(cell, baseURL: baseURL))</td>"
            }.joined()
            return "<tr>\(cellsHTML)</tr>"
        }.joined()

        return """
        <table>
            <thead><tr>\(headerHTML)</tr></thead>
            <tbody>\(rowsHTML)</tbody>
        </table>
        """
    }

    private static func alignmentAttribute(_ alignment: MarkdownTableAlignment?) -> String {
        guard let alignment else { return "" }
        return " align=\"\(alignment.rawValue)\""
    }

    private static func unavailableHTML(title: String, message: String) -> String {
        """
        <div class="empty-state">
            <div>
                <strong>\(escapeHTML(title))</strong>
                <span>\(escapeHTML(message))</span>
            </div>
        </div>
        """
    }

    private static func cssColor(_ color: NSColor) -> String {
        guard let rgb = resolvedRGBColor(color) else {
            return "#000000"
        }

        let red = Int(round(min(max(rgb.redComponent, 0), 1) * 255))
        let green = Int(round(min(max(rgb.greenComponent, 0), 1) * 255))
        let blue = Int(round(min(max(rgb.blueComponent, 0), 1) * 255))
        return "#\(hexPair(red))\(hexPair(green))\(hexPair(blue))"
    }

    private static func cssRGBA(_ color: NSColor, alpha: CGFloat) -> String {
        guard let rgb = resolvedRGBColor(color) else {
            return "rgba(0, 0, 0, \(decimal(alpha, places: 3)))"
        }

        let red = Int(round(min(max(rgb.redComponent, 0), 1) * 255))
        let green = Int(round(min(max(rgb.greenComponent, 0), 1) * 255))
        let blue = Int(round(min(max(rgb.blueComponent, 0), 1) * 255))
        return "rgba(\(red), \(green), \(blue), \(decimal(min(max(alpha, 0), 1), places: 3)))"
    }

    private static func resolvedRGBColor(_ color: NSColor) -> NSColor? {
        var resolvedColor: NSColor?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(NSColorSpace.sRGB)
                ?? color.usingColorSpace(NSColorSpace.deviceRGB)
        }
        return resolvedColor
    }

    private static func hexPair(_ value: Int) -> String {
        let digits = Array("0123456789ABCDEF")
        let clamped = min(max(value, 0), 255)
        return "\(digits[clamped / 16])\(digits[clamped % 16])"
    }

    private static func decimal(_ value: CGFloat, places: Int) -> String {
        let places = max(places, 0)
        let scale = Int(pow(10.0, Double(places)))
        let scaled = Int((Double(value) * Double(scale)).rounded())
        let whole = scaled / scale
        guard places > 0 else { return "\(whole)" }

        let fraction = abs(scaled % scale)
        let fractionText = String(fraction)
        let padding = String(repeating: "0", count: max(places - fractionText.count, 0))
        return "\(whole).\(padding)\(fractionText)"
    }

    private static func cssString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func sanitizedClassName(_ value: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = String(value.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? nil : escapeHTMLAttribute(filtered)
    }
}

private enum MarkdownInlineRenderer {
    static func render(_ source: String, baseURL: URL?) -> String {
        var output = ""
        var index = source.startIndex

        while index < source.endIndex {
            if source[index] == "<",
               let tag = MarkdownHTMLSanitizer.sanitizedTag(in: source, at: index, baseURL: baseURL) {
                output += tag.html
                index = tag.endIndex
                continue
            }

            if source[index] == "`",
               let code = codeSpan(in: source, at: index) {
                output += "<code>\(escapeHTML(code.text))</code>"
                index = code.endIndex
                continue
            }

            if source[index] == "!",
               let image = markdownImage(in: source, at: index) {
                if let target = MarkdownHTMLSanitizer.sanitizedURLString(
                    image.target,
                    allowDataImages: true,
                    baseURL: baseURL
                ) {
                    output += "<img src=\"\(escapeHTMLAttribute(target))\" alt=\"\(escapeHTMLAttribute(image.alt))\">"
                } else {
                    output += escapeHTML("![\(image.alt)](\(image.target))")
                }
                index = image.endIndex
                continue
            }

            if source[index] == "[",
               let link = markdownLink(in: source, at: index) {
                if let target = MarkdownHTMLSanitizer.sanitizedURLString(
                    link.target,
                    allowDataImages: false,
                    baseURL: baseURL
                ) {
                    output += "<a href=\"\(escapeHTMLAttribute(target))\" rel=\"noopener noreferrer\">\(render(link.label, baseURL: baseURL))</a>"
                } else {
                    output += escapeHTML("[\(link.label)](\(link.target))")
                }
                index = link.endIndex
                continue
            }

            if let emphasis = emphasis(in: source, at: index) {
                output += "<\(emphasis.tag)>\(render(emphasis.text, baseURL: baseURL))</\(emphasis.tag)>"
                index = emphasis.endIndex
                continue
            }

            if source[index] == "\n" {
                output += "<br>"
                index = source.index(after: index)
                continue
            }

            output += escapeHTML(String(source[index]))
            index = source.index(after: index)
        }

        return output
    }

    private static func codeSpan(in source: String, at index: String.Index) -> (text: String, endIndex: String.Index)? {
        guard source[index] == "`" else { return nil }
        let delimiterEnd = source.index(after: index)
        guard let closeRange = source[delimiterEnd...].range(of: "`") else { return nil }
        return (String(source[delimiterEnd..<closeRange.lowerBound]), closeRange.upperBound)
    }

    private static func markdownImage(in source: String, at index: String.Index) -> (alt: String, target: String, endIndex: String.Index)? {
        guard source[index] == "!" else { return nil }
        let labelStart = source.index(after: index)
        guard labelStart < source.endIndex, source[labelStart] == "[" else { return nil }
        guard let parsed = bracketedLink(in: source, at: labelStart) else { return nil }
        return (parsed.label, parsed.target, parsed.endIndex)
    }

    private static func markdownLink(in source: String, at index: String.Index) -> (label: String, target: String, endIndex: String.Index)? {
        guard source[index] == "[" else { return nil }
        return bracketedLink(in: source, at: index)
    }

    private static func bracketedLink(in source: String, at index: String.Index) -> (label: String, target: String, endIndex: String.Index)? {
        guard let labelEnd = source[index...].firstIndex(of: "]") else { return nil }
        let parenStart = source.index(after: labelEnd)
        guard parenStart < source.endIndex, source[parenStart] == "(" else { return nil }
        guard let targetEnd = source[parenStart...].firstIndex(of: ")") else { return nil }

        let labelStart = source.index(after: index)
        let targetStart = source.index(after: parenStart)
        return (
            String(source[labelStart..<labelEnd]),
            String(source[targetStart..<targetEnd]),
            source.index(after: targetEnd)
        )
    }

    private static func emphasis(in source: String, at index: String.Index) -> (tag: String, text: String, endIndex: String.Index)? {
        for candidate in [
            (delimiter: "**", tag: "strong"),
            (delimiter: "__", tag: "strong"),
            (delimiter: "~~", tag: "del"),
            (delimiter: "*", tag: "em")
        ] {
            guard source[index...].hasPrefix(candidate.delimiter) else { continue }
            let contentStart = source.index(index, offsetBy: candidate.delimiter.count)
            guard contentStart < source.endIndex,
                  let closeRange = source[contentStart...].range(of: candidate.delimiter),
                  closeRange.lowerBound > contentStart else { continue }
            return (
                candidate.tag,
                String(source[contentStart..<closeRange.lowerBound]),
                closeRange.upperBound
            )
        }

        return nil
    }
}

private enum MarkdownHTMLSanitizer {
    private static let maximumEmbeddedImageBytes = 25_000_000
    private static let allowedTags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "caption", "code", "col", "colgroup",
        "dd", "del", "details", "div", "dl", "dt", "em", "figcaption", "figure",
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "kbd", "li",
        "mark", "ol", "p", "pre", "s", "small", "span", "strong", "sub", "summary",
        "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "u", "ul"
    ]
    private static let voidTags: Set<String> = ["br", "col", "hr", "img"]
    private static let attributeRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s"'=<>`]+))?"#
    )

    static func sanitizedTag(
        in source: String,
        at index: String.Index,
        baseURL: URL?
    ) -> (html: String, endIndex: String.Index)? {
        guard source[index] == "<",
              let close = source[index...].firstIndex(of: ">") else { return nil }

        let tagEnd = source.index(after: close)
        let rawTag = String(source[index..<tagEnd])
        return (sanitizedTag(rawTag, baseURL: baseURL) ?? escapeHTML(rawTag), tagEnd)
    }

    static func sanitizedURLString(
        _ rawValue: String,
        allowDataImages: Bool,
        baseURL: URL?
    ) -> String? {
        var value = resourceURLPart(from: rawValue)
        if value.hasPrefix("<"), value.hasSuffix(">") {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty else { return nil }

        let lowercased = value.lowercased()
        if lowercased.hasPrefix("javascript:")
            || lowercased.hasPrefix("vbscript:")
            || lowercased.hasPrefix("data:text/html") {
            return nil
        }

        if lowercased.hasPrefix("data:") {
            guard allowDataImages,
                  lowercased.hasPrefix("data:image/png")
                    || lowercased.hasPrefix("data:image/jpeg")
                    || lowercased.hasPrefix("data:image/jpg")
                    || lowercased.hasPrefix("data:image/gif")
                    || lowercased.hasPrefix("data:image/webp") else { return nil }
            return value
        }

        if let absoluteURL = URL(string: value),
           let scheme = absoluteURL.scheme?.lowercased(),
           !scheme.isEmpty {
            guard ["http", "https", "file", "mailto"].contains(scheme) else { return nil }
            if allowDataImages,
               scheme == "file",
               let dataURL = embeddedImageDataURL(for: absoluteURL) {
                return dataURL
            }
            return value
        }

        if value.hasPrefix("/") {
            let fileURL = URL(fileURLWithPath: value)
            if allowDataImages, let dataURL = embeddedImageDataURL(for: fileURL) {
                return dataURL
            }
            return fileURL.absoluteString
        }

        if let baseURL {
            let resolvedURL = URL(fileURLWithPath: value, relativeTo: baseURL).standardizedFileURL
            if allowDataImages, let dataURL = embeddedImageDataURL(for: resolvedURL) {
                return dataURL
            }
            return resolvedURL.absoluteString
        }

        return value
    }

    static func isSafeLinkURL(_ rawValue: String) -> Bool {
        sanitizedURLString(rawValue, allowDataImages: false, baseURL: nil) != nil
    }

    private static func sanitizedTag(_ rawTag: String, baseURL: URL?) -> String? {
        var body = rawTag
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        guard !body.hasPrefix("!") && !body.hasPrefix("?") else { return "" }

        if body.hasPrefix("/") {
            body = body.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            let name = tagName(from: body)
            guard allowedTags.contains(name) else { return "" }
            return "</\(name)>"
        }

        let isSelfClosing = body.hasSuffix("/")
        if isSelfClosing {
            body = body.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let name = tagName(from: body)
        guard allowedTags.contains(name) else { return "" }

        let attributesSource = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let attributes = sanitizedAttributes(String(attributesSource), for: name, baseURL: baseURL)
        let renderedAttributes = attributes.isEmpty ? "" : " \(attributes.joined(separator: " "))"

        if voidTags.contains(name) || isSelfClosing {
            return "<\(name)\(renderedAttributes)>"
        }
        return "<\(name)\(renderedAttributes)>"
    }

    private static func tagName(from body: String) -> String {
        let scalars = body.unicodeScalars
        let nameScalars = scalars.prefix { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return String(String.UnicodeScalarView(nameScalars)).lowercased()
    }

    private static func sanitizedAttributes(_ source: String, for tag: String, baseURL: URL?) -> [String] {
        guard let attributeRegex else { return [] }

        let nsSource = source as NSString
        let matches = attributeRegex.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        var attributes: [String] = []
        var hasSafeHref = false

        for match in matches {
            let rawName = nsSource.substring(with: match.range(at: 1)).lowercased()
            guard isAllowedAttribute(rawName, for: tag) else { continue }

            let value: String?
            if match.range(at: 2).location != NSNotFound {
                value = unquotedAttributeValue(nsSource.substring(with: match.range(at: 2)))
            } else {
                value = nil
            }

            if rawName == "href" || rawName == "src" {
                guard let value,
                      let sanitizedURL = sanitizedURLString(
                        value,
                        allowDataImages: rawName == "src",
                        baseURL: baseURL
                      ) else { continue }
                attributes.append("\(rawName)=\"\(escapeHTMLAttribute(sanitizedURL))\"")
                hasSafeHref = hasSafeHref || rawName == "href"
                continue
            }

            if rawName == "align" {
                guard let value,
                      let alignment = sanitizedAlignment(value) else { continue }
                attributes.append("align=\"\(alignment)\"")
                continue
            }

            if ["width", "height", "colspan", "rowspan", "start"].contains(rawName) {
                guard let value,
                      value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.%").contains($0) }) else { continue }
                attributes.append("\(rawName)=\"\(escapeHTMLAttribute(value))\"")
                continue
            }

            if rawName == "open" {
                attributes.append(rawName)
                continue
            }

            guard let value else { continue }
            attributes.append("\(rawName)=\"\(escapeHTMLAttribute(value))\"")
        }

        if tag == "a", hasSafeHref {
            attributes.append("rel=\"noopener noreferrer\"")
        }

        return attributes
    }

    private static func isAllowedAttribute(_ attribute: String, for tag: String) -> Bool {
        guard !attribute.hasPrefix("on"),
              attribute != "style",
              attribute != "srcdoc" else { return false }

        let globalAttributes: Set<String> = ["title", "class", "id", "aria-label"]
        if globalAttributes.contains(attribute) { return true }

        switch tag {
        case "a":
            return attribute == "href"
        case "img":
            return ["src", "alt", "title", "width", "height"].contains(attribute)
        case "td", "th":
            return ["colspan", "rowspan", "align"].contains(attribute)
        case "ol":
            return attribute == "start"
        case "details":
            return attribute == "open"
        default:
            return attribute == "align" && supportsAlignAttribute(tag)
        }
    }

    private static func supportsAlignAttribute(_ tag: String) -> Bool {
        switch tag {
        case "p", "div", "blockquote", "figure", "figcaption",
             "h1", "h2", "h3", "h4", "h5", "h6":
            return true
        default:
            return false
        }
    }

    private static func sanitizedAlignment(_ value: String) -> String? {
        let alignment = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch alignment {
        case "left", "right", "center", "justify", "start", "end":
            return alignment
        default:
            return nil
        }
    }

    private static func unquotedAttributeValue(_ value: String) -> String {
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func resourceURLPart(from rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }

        if value.hasPrefix("<"),
           let closingBracket = value.firstIndex(of: ">") {
            return String(value[value.index(after: value.startIndex)..<closingBracket])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var cursor = value.startIndex
        while cursor < value.endIndex {
            if value[cursor].isWhitespace {
                return String(value[..<cursor])
            }
            cursor = value.index(after: cursor)
        }

        return value
    }

    private static func embeddedImageDataURL(for url: URL) -> String? {
        guard url.isFileURL,
              let mimeType = imageMimeType(for: url.pathExtension) else { return nil }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            guard (values.fileSize ?? 0) <= maximumEmbeddedImageBytes else { return nil }

            let data = try Data(contentsOf: url)
            guard data.count <= maximumEmbeddedImageBytes else { return nil }
            return "data:\(mimeType);base64,\(data.base64EncodedString())"
        } catch {
            return nil
        }
    }

    private static func imageMimeType(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "bmp":
            return "image/bmp"
        case "tif", "tiff":
            return "image/tiff"
        case "heic":
            return "image/heic"
        case "ico":
            return "image/x-icon"
        default:
            return nil
        }
    }
}

private enum MarkdownPreviewBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([MarkdownPreviewListItem])
    case orderedList([MarkdownPreviewListItem])
    case blockquote(String)
    case table(MarkdownPreviewTable)
    case code(language: String?, text: String)
    case image(MarkdownPreviewImage)
    case rule
}

private struct MarkdownPreviewListItem {
    let text: String
    let checklistState: MarkdownChecklistState?
    let children: [MarkdownPreviewListBlock]
}

private struct MarkdownPreviewListBlock {
    let ordered: Bool
    let items: [MarkdownPreviewListItem]
}

private enum MarkdownChecklistState {
    case checked
    case unchecked
}

private struct MarkdownPreviewImage {
    let alt: String
    let target: String
}

private struct MarkdownPreviewTable {
    let header: [String]
    let alignments: [MarkdownTableAlignment?]
    let rows: [[String]]
}

private enum MarkdownTableAlignment: String {
    case left
    case center
    case right
}

private enum MarkdownPreviewParser {
    static func parse(_ markdown: String) -> [MarkdownPreviewBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownPreviewBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceStart(in: trimmed) {
                let parsed = parseFence(lines: lines, startingAt: index, fence: fence)
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if let table = parseTable(lines: lines, startingAt: index) {
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }

            if let image = standaloneImage(from: trimmed) {
                blocks.append(.image(image))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                let parsed = parseBlockquote(lines: lines, startingAt: index)
                blocks.append(.blockquote(parsed.text))
                index = parsed.nextIndex
                continue
            }

            if let marker = unorderedListMarker(from: line) {
                let parsed = parseList(
                    lines: lines,
                    startingAt: index,
                    ordered: false,
                    baseIndent: marker.indent
                )
                blocks.append(.unorderedList(parsed.items))
                index = parsed.nextIndex
                continue
            }

            if let marker = orderedListMarker(from: line) {
                let parsed = parseList(
                    lines: lines,
                    startingAt: index,
                    ordered: true,
                    baseIndent: marker.indent
                )
                blocks.append(.orderedList(parsed.items))
                index = parsed.nextIndex
                continue
            }

            let parsed = parseParagraph(lines: lines, startingAt: index)
            blocks.append(.paragraph(parsed.text))
            index = parsed.nextIndex
        }

        return blocks
    }

    private static func fenceStart(in trimmed: String) -> (marker: String, language: String)? {
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let markerCharacter = trimmed.first ?? "`"
        let markerLength = trimmed.prefix { $0 == markerCharacter }.count
        guard markerLength >= 3 else { return nil }

        let marker = String(repeating: String(markerCharacter), count: markerLength)
        let language = trimmed.dropFirst(markerLength).trimmingCharacters(in: .whitespaces)
        return (marker, language.isEmpty ? "" : language)
    }

    private static func parseFence(
        lines: [String],
        startingAt index: Int,
        fence: (marker: String, language: String)
    ) -> (block: MarkdownPreviewBlock, nextIndex: Int) {
        var codeLines: [String] = []
        var cursor = index + 1

        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence.marker) {
                cursor += 1
                break
            }
            codeLines.append(lines[cursor])
            cursor += 1
        }

        return (
            .code(
                language: fence.language.isEmpty ? nil : fence.language,
                text: codeLines.joined(separator: "\n")
            ),
            cursor
        )
    }

    private static func heading(from trimmed: String) -> (level: Int, text: String)? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }

        let remainder = trimmed.dropFirst(level)
        guard remainder.first?.isWhitespace == true else { return nil }

        return (level, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let characters = trimmed.filter { !$0.isWhitespace }
        guard characters.count >= 3, let first = characters.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return characters.allSatisfy { $0 == first }
    }

    private static func standaloneImage(from trimmed: String) -> MarkdownPreviewImage? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
        guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
        let openParen = trimmed.index(after: closeBracket)
        guard openParen < trimmed.endIndex, trimmed[openParen] == "(" else { return nil }

        let altStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let targetStart = trimmed.index(after: openParen)
        let targetEnd = trimmed.index(before: trimmed.endIndex)
        guard targetStart <= targetEnd else { return nil }

        return MarkdownPreviewImage(
            alt: String(trimmed[altStart..<closeBracket]),
            target: String(trimmed[targetStart..<targetEnd])
        )
    }

    private static func parseBlockquote(lines: [String], startingAt index: Int) -> (text: String, nextIndex: Int) {
        var quoteLines: [String] = []
        var cursor = index

        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }

            var quote = String(trimmed.dropFirst())
            if quote.first?.isWhitespace == true {
                quote = String(quote.dropFirst())
            }
            quoteLines.append(quote)
            cursor += 1
        }

        return (quoteLines.joined(separator: "\n"), cursor)
    }

    private static func parseTable(lines: [String], startingAt index: Int) -> (block: MarkdownPreviewBlock, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headerCells = tableCells(from: lines[index]),
              let separator = tableSeparator(from: lines[index + 1]) else { return nil }

        let columnCount = max(headerCells.count, separator.count)
        guard columnCount > 0 else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2

        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let cells = tableCells(from: lines[cursor]) else { break }

            rows.append(normalizedTableCells(cells, columnCount: columnCount))
            cursor += 1
        }

        let table = MarkdownPreviewTable(
            header: normalizedTableCells(headerCells, columnCount: columnCount),
            alignments: normalizedAlignments(separator, columnCount: columnCount),
            rows: rows
        )
        return (.table(table), cursor)
    }

    private static func tableSeparator(from line: String) -> [MarkdownTableAlignment?]? {
        guard let cells = tableCells(from: line) else { return nil }

        var alignments: [MarkdownTableAlignment?] = []
        for cell in cells {
            let compact = String(cell.filter { !$0.isWhitespace })
            guard compact.count >= 3 else { return nil }

            let startsWithColon = compact.hasPrefix(":")
            let endsWithColon = compact.hasSuffix(":")
            let dashStart = startsWithColon ? compact.index(after: compact.startIndex) : compact.startIndex
            let dashEnd = endsWithColon ? compact.index(before: compact.endIndex) : compact.endIndex
            guard dashStart < dashEnd,
                  compact[dashStart..<dashEnd].allSatisfy({ $0 == "-" }) else { return nil }

            if startsWithColon && endsWithColon {
                alignments.append(.center)
            } else if endsWithColon {
                alignments.append(.right)
            } else if startsWithColon {
                alignments.append(.left)
            } else {
                alignments.append(nil)
            }
        }

        return alignments.isEmpty ? nil : alignments
    }

    private static func tableCells(from line: String) -> [String]? {
        guard lineContainsUnescapedPipe(line) else { return nil }

        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var current = ""
        var cursor = line.startIndex

        while cursor < line.endIndex {
            let character = line[cursor]

            if character == "\\" {
                let nextIndex = line.index(after: cursor)
                if nextIndex < line.endIndex, line[nextIndex] == "|" {
                    current.append("|")
                    cursor = line.index(after: nextIndex)
                    continue
                }
            }

            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }

            cursor = line.index(after: cursor)
        }

        cells.append(current.trimmingCharacters(in: .whitespaces))

        if trimmedLine.hasPrefix("|"), cells.first == "" {
            cells.removeFirst()
        }
        if trimmedLine.hasSuffix("|"), cells.last == "" {
            cells.removeLast()
        }

        return cells.isEmpty ? nil : cells
    }

    private static func lineContainsUnescapedPipe(_ line: String) -> Bool {
        var cursor = line.startIndex

        while cursor < line.endIndex {
            if line[cursor] == "\\" {
                cursor = line.index(after: cursor)
                if cursor < line.endIndex {
                    cursor = line.index(after: cursor)
                }
                continue
            }

            if line[cursor] == "|" {
                return true
            }

            cursor = line.index(after: cursor)
        }

        return false
    }

    private static func normalizedTableCells(_ cells: [String], columnCount: Int) -> [String] {
        if cells.count >= columnCount {
            return Array(cells.prefix(columnCount))
        }
        return cells + Array(repeating: "", count: columnCount - cells.count)
    }

    private static func normalizedAlignments(
        _ alignments: [MarkdownTableAlignment?],
        columnCount: Int
    ) -> [MarkdownTableAlignment?] {
        if alignments.count >= columnCount {
            return Array(alignments.prefix(columnCount))
        }
        return alignments + Array(repeating: nil, count: columnCount - alignments.count)
    }

    private static func parseList(
        lines: [String],
        startingAt index: Int,
        ordered: Bool,
        baseIndent: Int
    ) -> (items: [MarkdownPreviewListItem], nextIndex: Int) {
        var items: [MarkdownPreviewListItem] = []
        var cursor = index

        while cursor < lines.count {
            guard let marker = listMarker(from: lines[cursor]),
                  marker.ordered == ordered,
                  marker.indent == baseIndent
            else { break }

            var combinedText = marker.text
            var children: [MarkdownPreviewListBlock] = []
            cursor += 1

            while cursor < lines.count {
                let nextLine = lines[cursor]
                let trimmed = nextLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    break
                }

                if let nextMarker = listMarker(from: nextLine) {
                    if nextMarker.indent > baseIndent {
                        let parsed = parseList(
                            lines: lines,
                            startingAt: cursor,
                            ordered: nextMarker.ordered,
                            baseIndent: nextMarker.indent
                        )
                        children.append(
                            MarkdownPreviewListBlock(
                                ordered: nextMarker.ordered,
                                items: parsed.items
                            )
                        )
                        cursor = parsed.nextIndex
                        continue
                    }
                    break
                }

                guard indentationColumn(in: nextLine) > baseIndent,
                      !blockStart(nextLine) else { break }

                combinedText += " " + trimmed
                cursor += 1
            }

            items.append(listItem(from: combinedText, children: children))
        }

        return (items, cursor)
    }

    private static func parseParagraph(lines: [String], startingAt index: Int) -> (text: String, nextIndex: Int) {
        var paragraphLines: [String] = []
        var cursor = index

        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !blockStart(line),
                  parseTable(lines: lines, startingAt: cursor) == nil else { break }
            paragraphLines.append(trimmed)
            cursor += 1
        }

        return (paragraphLines.joined(separator: " "), cursor)
    }

    private static func blockStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            || fenceStart(in: trimmed) != nil
            || heading(from: trimmed) != nil
            || isRule(trimmed)
            || standaloneImage(from: trimmed) != nil
            || trimmed.hasPrefix(">")
            || unorderedListItemText(from: line) != nil
            || orderedListItemText(from: line) != nil
    }

    private static func unorderedListItemText(from line: String) -> String? {
        unorderedListMarker(from: line)?.text
    }

    private static func unorderedListMarker(from line: String) -> MarkdownListMarker? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let marker = trimmed.first else { return nil }
        guard marker == "-" || marker == "*" || marker == "+" else { return nil }

        let afterMarker = trimmed.index(after: trimmed.startIndex)
        guard afterMarker < trimmed.endIndex, trimmed[afterMarker].isWhitespace else { return nil }
        return MarkdownListMarker(
            indent: indentationColumn(in: line),
            ordered: false,
            text: String(trimmed[afterMarker...]).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func orderedListItemText(from line: String) -> String? {
        orderedListMarker(from: line)?.text
    }

    private static func orderedListMarker(from line: String) -> MarkdownListMarker? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var cursor = trimmed.startIndex
        var digitCount = 0

        while cursor < trimmed.endIndex, trimmed[cursor].isNumber {
            digitCount += 1
            cursor = trimmed.index(after: cursor)
        }

        guard digitCount > 0, cursor < trimmed.endIndex else { return nil }
        guard trimmed[cursor] == "." || trimmed[cursor] == ")" else { return nil }
        cursor = trimmed.index(after: cursor)
        guard cursor < trimmed.endIndex, trimmed[cursor].isWhitespace else { return nil }

        return MarkdownListMarker(
            indent: indentationColumn(in: line),
            ordered: true,
            text: String(trimmed[cursor...]).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func listMarker(from line: String) -> MarkdownListMarker? {
        unorderedListMarker(from: line) ?? orderedListMarker(from: line)
    }

    private static func listItem(
        from text: String,
        children: [MarkdownPreviewListBlock]
    ) -> MarkdownPreviewListItem {
        if text.hasPrefix("[ ] ") {
            return MarkdownPreviewListItem(
                text: String(text.dropFirst(4)),
                checklistState: .unchecked,
                children: children
            )
        }

        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            return MarkdownPreviewListItem(
                text: String(text.dropFirst(4)),
                checklistState: .checked,
                children: children
            )
        }

        return MarkdownPreviewListItem(
            text: text,
            checklistState: nil,
            children: children
        )
    }

    private static func indentationColumn(in line: String) -> Int {
        var column = 0

        for character in line {
            if character == " " {
                column += 1
            } else if character == "\t" {
                let remainder = column % 4
                column += remainder == 0 ? 4 : 4 - remainder
            } else {
                break
            }
        }

        return column
    }
}

private struct MarkdownListMarker {
    let indent: Int
    let ordered: Bool
    let text: String
}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func escapeHTMLAttribute(_ value: String) -> String {
    escapeHTML(value)
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
