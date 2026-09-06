import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct DocumentSettingsTests {
    @Test func fastMathDefaultsOnAndRoundTrips() throws {
        var s = DocumentSettings()
        #expect(s.fastMath == true)
        s.fastMath = false
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: data).fastMath == false)
    }

    @Test func missingFastMathKeyDecodesAsTrue() throws {
        let legacy = #"{"previewSize":[512,512],"timeMode":"wallClock"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(DocumentSettings.self, from: legacy)
        #expect(s.fastMath == true)
        #expect(s.timeMode == .wallClock)
    }

    @Test func targetAndExportNameRoundTripAndDefault() throws {
        var s = DocumentSettings()
        #expect(s.target == .fragment)
        #expect(s.exportName == "metalNodesShader")
        s.target = .stitchable(.distortionEffect)
        s.exportName = "ripple"
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(DocumentSettings.self, from: data)
        #expect(back.target == .stitchable(.distortionEffect))
        #expect(back.exportName == "ripple")
        let legacy = try JSONDecoder().decode(DocumentSettings.self, from: Data(#"{"fastMath":false}"#.utf8))
        #expect(legacy.target == .fragment)
        #expect(legacy.exportName == "metalNodesShader")
    }

    @Test func outputTargetsHaveTitlesAndAStableOrder() {
        #expect(OutputTarget.all.count == 4)
        #expect(OutputTarget.all.first == .fragment)
        #expect(OutputTarget.stitchable(.layerEffect).title == "SwiftUI Layer Effect")
        #expect(OutputTarget.stitchable(.colorEffect).stitchableKind == .colorEffect)
        #expect(OutputTarget.fragment.stitchableKind == nil)
    }
}
