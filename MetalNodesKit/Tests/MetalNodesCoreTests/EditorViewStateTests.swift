import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

/// View state is persisted next to the document and read back by older and newer builds alike
/// (spec §5, §22.2): a key that is not there must decode as the default, never as a failure.
@Suite struct EditorViewStateTests {
    @Test func freshStateStartsInPointerModeWithTheInspectorShowing() {
        let s = EditorViewState()
        #expect(s.canvasMode == .pointer)
        #expect(s.showsInspector)
    }

    @Test func jsonWithoutTheM6KeysDecodesAsTheDefaults() throws {
        // An M5 view.json: none of the M6 keys exist in it.
        let json = Data("{}".utf8)
        let s = try JSONDecoder().decode(EditorViewState.self, from: json)
        #expect(s.canvasMode == .pointer)
        #expect(s.showsInspector)
        #expect(s == EditorViewState())          // and nothing else drifted
    }

    @Test func canvasModeAndInspectorRoundTrip() throws {
        var s = EditorViewState()
        s.canvasMode = .lasso
        s.showsInspector = false
        s.showsCode = true
        s.cameras[.root] = Camera(pan: CGSize(width: 3, height: 4), zoom: 2)
        let back = try JSONDecoder().decode(EditorViewState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    /// The mode is persisted by name, so the three spellings are file format and may not be
    /// renamed without a migration.
    @Test func modesEncodeAsTheirNames() throws {
        #expect(CanvasMode.allCases.map(\.rawValue) == ["pointer", "select", "lasso"])
        var s = EditorViewState()
        s.canvasMode = .select
        let text = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(text.contains("\"canvasMode\":\"select\""))
        #expect(text.contains("\"showsInspector\":true"))
    }
}
