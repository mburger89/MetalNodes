import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct IdentifierTests {
    @Test func freshIDsAreDistinct() {
        #expect(NodeID() != NodeID())
    }

    @Test func idRoundTripsThroughJSONAsBareString() throws {
        let id = NodeID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)
        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"00000000-0000-0000-0000-000000000042\"")
        #expect(try JSONDecoder().decode(NodeID.self, from: data) == id)
    }
}
