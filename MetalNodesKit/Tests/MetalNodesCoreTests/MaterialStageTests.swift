import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct MaterialStageTests {
    @Test func allIsBothStages() {
        #expect(MaterialStage.all == [.surface, .geometry])
        #expect(Set(MaterialStage.allCases) == MaterialStage.all)
    }

    @Test func stagesRoundTripThroughCoding() throws {
        let data = try JSONEncoder().encode([MaterialStage.geometry])
        #expect(try JSONDecoder().decode([MaterialStage].self, from: data) == [.geometry])
    }

    @Test func realityKitIsAnOutputTargetWithATitle() {
        #expect(OutputTarget.all.contains(.realityKit))
        #expect(OutputTarget.realityKit.title == "RealityKit Material")
        #expect(OutputTarget.realityKit.stitchableKind == nil)
    }

    @Test func everyBuiltinNodeIsLegalInBothStagesByDefault() {
        // Task 2 narrows a handful; before it lands, the default must be "both".
        for def in NodeRegistry.builtin.all where !def.id.hasPrefix("input.") {
            #expect(def.stages == MaterialStage.all, "\(def.id)")
        }
    }
}
