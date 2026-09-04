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
}
