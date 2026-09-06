import Foundation
import SwiftUI

/// Dracula syntax colouring for the generated-code panel (spec §21.5). A pure function over the
/// string — it runs once per successful generation, not per keystroke, so a per-line scan is fine.
public enum MSLHighlighter {
    private static let keywords: Set<String> = [
        "float", "float2", "float3", "float4",
        "half", "half2", "half3", "half4",
        "struct", "return", "constant", "texture2d", "sampler",
        "fragment", "using", "namespace",
    ]

    /// `[[…]]` attributes, numbers, and identifiers, in that priority order (attributes contain
    /// characters — like spaces — the identifier/number patterns don't match, so they must come first).
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"\[\[[^\]]*\]\]|\b\d+\.\d+[fF]?\b|\b\d+[fF]?\b|\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    /// `highlightLines` is 1-based, matching `LineMap`.
    public static func attributed(_ source: String, highlightLines: Set<Int>) -> AttributedString {
        guard !source.isEmpty else { return AttributedString() }
        let lines = source.components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var lineAttr = attributedLine(line)
            if highlightLines.contains(index + 1) {
                lineAttr.backgroundColor = DraculaTheme.currentLine.color
            }
            result += lineAttr
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    private static func attributedLine(_ line: String) -> AttributedString {
        let leading = line.drop { $0 == " " || $0 == "\t" }
        if leading.hasPrefix("#") {
            var a = AttributedString(line)
            a.foregroundColor = DraculaToken.pink.color
            return a
        }
        if let commentRange = line.range(of: "//") {
            let code = String(line[line.startIndex..<commentRange.lowerBound])
            let comment = String(line[commentRange.lowerBound...])
            var result = attributedCode(code)
            var c = AttributedString(comment)
            c.foregroundColor = DraculaTheme.comment.color
            result += c
            return result
        }
        return attributedCode(line)
    }

    private static func attributedCode(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        let ns = text as NSString
        var result = AttributedString()
        var lastEnd = 0
        let matches = tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if m.range.location > lastEnd {
                result += foreground(ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd)))
            }
            let token = ns.substring(with: m.range)
            var a = AttributedString(token)
            a.foregroundColor = color(for: token)
            result += a
            lastEnd = m.range.location + m.range.length
        }
        if lastEnd < ns.length {
            result += foreground(ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd)))
        }
        return result
    }

    private static func foreground(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = DraculaToken.foreground.color
        return a
    }

    private static func color(for token: String) -> Color {
        if token.hasPrefix("[[") { return DraculaToken.purple.color }
        if let first = token.first, first.isNumber { return DraculaToken.orange.color }
        if keywords.contains(token) { return DraculaToken.purple.color }
        return DraculaToken.foreground.color
    }
}
