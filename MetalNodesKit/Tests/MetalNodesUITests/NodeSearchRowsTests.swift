import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

/// `PaletteSearch.rows` for the ⇧A search popover (spec §21.7): builtins first, then the
/// document's group definitions ("My Functions"), both filtered by the same query.
@Suite struct NodeSearchRowsTests {
    let registry = NodeRegistry.builtin

    private func document(named names: [String]) -> ShaderDocument {
        var doc = ShaderDocument()
        for n in names {
            let d = GroupDefinition.make(name: n)
            doc.definitions[d.id] = d
        }
        return doc
    }

    @Test func emptyQueryListsAllBuiltinsThenAllDefinitions() {
        let doc = document(named: ["Turbulence", "Fbm"])
        let rows = PaletteSearch.rows(query: "", registry: registry, document: doc)

        let builtinCount = registry.all.count
        #expect(rows.count == builtinCount + 2)

        let builtinRows = rows.prefix(builtinCount)
        let definitionRows = rows.suffix(2)
        #expect(builtinRows.allSatisfy { if case .builtin = $0 { true } else { false } })
        #expect(definitionRows.allSatisfy { if case .definition = $0 { true } else { false } })

        // Definitions are sorted by name, same as `filterDefinitions`.
        let names = definitionRows.compactMap { row -> String? in
            if case .definition(let d) = row { return d.name }
            return nil
        }
        #expect(names == ["Fbm", "Turbulence"])
    }

    @Test func queryMatchesADefinitionByName() {
        let doc = document(named: ["Group Blend", "Unrelated"])
        let rows = PaletteSearch.rows(query: "gro", registry: registry, document: doc)

        let definitionNames = rows.compactMap { row -> String? in
            if case .definition(let d) = row { return d.name }
            return nil
        }
        #expect(definitionNames == ["Group Blend"])
        // No builtin id or title contains "gro", so the builtin section is empty for this query.
        #expect(rows.allSatisfy {
            if case .builtin(let d) = $0 { return d.title.lowercased().contains("gro") || d.id.lowercased().contains("gro") }
            return true
        })
    }

    @Test func builtinOnlyQueryListsNoDefinitions() {
        let doc = document(named: ["Turbulence"])
        // "value noise" matches only the builtin "noise.value" and no definition name.
        let rows = PaletteSearch.rows(query: "value noise", registry: registry, document: doc)

        #expect(rows.map(\.id) == [SearchRow.builtin(registry["noise.value"]!)].map(\.id))
        #expect(rows.allSatisfy { if case .definition = $0 { false } else { true } })
    }

    /// A wire-drop chooser must filter "My Functions" rows by input compatibility the same way it
    /// filters builtins, so a definition with no compatible input never appears (spec §21.7).
    @Test func acceptsInputAppliesToDefinitionsSymmetricallyWithBuiltins() {
        var floatOnly = GroupDefinition.make(name: "Blend")
        floatOnly.inputs = [SocketDecl(name: "amount", type: .concrete(.float))]

        #expect(PaletteSearch.acceptsInput(of: .float, floatOnly))
        #expect(PaletteSearch.acceptsInput(of: .texture, floatOnly) == false)

        var noInputs = GroupDefinition.make(name: "Constant")
        noInputs.inputs = []
        #expect(PaletteSearch.acceptsInput(of: .float, noInputs) == false)
    }
}
