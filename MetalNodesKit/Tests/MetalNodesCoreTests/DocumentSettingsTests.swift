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
        // M7 adds `.realityKit` as a fifth target (MaterialStageTests.realityKitIsAnOutputTargetWithATitle).
        #expect(OutputTarget.all.count == 5)
        #expect(OutputTarget.all.first == .fragment)
        #expect(OutputTarget.stitchable(.layerEffect).title == "SwiftUI Layer Effect")
        #expect(OutputTarget.stitchable(.colorEffect).stitchableKind == .colorEffect)
        #expect(OutputTarget.fragment.stitchableKind == nil)
    }
}

@Suite struct MaterialDocumentSettingsTests {
    @Test func lightingModelDefaultsToLitAndRoundTrips() throws {
        var s = DocumentSettings()
        #expect(s.lightingModel == .lit)
        s.lightingModel = .unlit
        s.target = .realityKit
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(DocumentSettings.self, from: data)
        #expect(back.lightingModel == .unlit)
        #expect(back.target == .realityKit)
    }

    @Test func settingsWithoutALightingModelDecodeAsLit() throws {
        let json = Data(#"{"fastMath":true,"exportName":"x"}"#.utf8)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: json).lightingModel == .lit)
    }

    /// A document written by a newer build must open, not fail: an unrecognised target
    /// falls back to Fragment rather than throwing out the whole settings object.
    @Test func anUnknownTargetFallsBackToFragment() throws {
        let json = Data(#"{"target":{"holographic":{}},"exportName":"x"}"#.utf8)
        let back = try JSONDecoder().decode(DocumentSettings.self, from: json)
        #expect(back.target == .fragment)
        #expect(back.exportName == "x")
    }
}
