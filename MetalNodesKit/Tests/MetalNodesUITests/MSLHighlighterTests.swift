import Testing
import SwiftUI
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct MSLHighlighterTests {
    @Test func keywordRunIsPurple() {
        let attributed = MSLHighlighter.attributed("float4 shaderMain() {}", highlightLines: [])
        let range = attributed.range(of: "float4")!
        #expect(attributed[range].foregroundColor == DraculaToken.purple.color)
    }

    @Test func commentRunIsCommentColor() {
        let attributed = MSLHighlighter.attributed("float x; // a comment", highlightLines: [])
        let range = attributed.range(of: "// a comment")!
        #expect(attributed[range].foregroundColor == DraculaTheme.comment.color)
    }

    @Test func includeDirectiveIsPink() {
        let attributed = MSLHighlighter.attributed("#include <metal_stdlib>", highlightLines: [])
        let range = attributed.range(of: "#include")!
        #expect(attributed[range].foregroundColor == DraculaToken.pink.color)
    }

    @Test func highlightedLineHasCurrentLineBackground() {
        let source = "float a;\nfloat b;\nfloat c;"
        let attributed = MSLHighlighter.attributed(source, highlightLines: [2])

        let highlighted = attributed.range(of: "float b;")!
        #expect(attributed[highlighted].backgroundColor == DraculaTheme.currentLine.color)

        let untouched = attributed.range(of: "float a;")!
        #expect(attributed[untouched].backgroundColor == nil)
    }

    @Test func unknownTextIsForeground() {
        let attributed = MSLHighlighter.attributed("someIdentifier", highlightLines: [])
        let range = attributed.range(of: "someIdentifier")!
        #expect(attributed[range].foregroundColor == DraculaToken.foreground.color)
    }

    @Test func emptyInputProducesEmptyOutput() {
        #expect(MSLHighlighter.attributed("", highlightLines: []) == AttributedString())
    }
}
