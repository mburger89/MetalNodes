import Testing
@testable import MetalNodesCore

@Suite struct NodeRegistryTests {
    private let add = NodeDef(
        id: "test.add", title: "Add", category: .math,
        inputs: [SocketDecl(name: "a", type: .generic("T"), default: .value(.float(0))),
                 SocketDecl(name: "b", type: .generic("T"), default: .value(.float(0)))],
        outputs: [SocketDecl(name: "out", type: .generic("T"))],
        generics: ["T": [.float, .float2, .float3, .float4]],
        body: .template("{out.out} = {in.a} + {in.b};"))

    @Test func lookupByID() throws {
        let reg = try NodeRegistry([add])
        #expect(reg["test.add"]?.title == "Add")
        #expect(reg["nope"] == nil)
        #expect(reg.all.map(\.id) == ["test.add"])
    }

    @Test func duplicateIDsAreRejected() {
        #expect(throws: RegistryError.duplicateID("test.add")) { try NodeRegistry([add, add]) }
    }

    @Test func socketAndParamNamesShareOneNamespace() {
        var def = add
        def.params = [ParamDecl(name: "a", kind: .value(.float, range: nil), defaultValue: .float(1))]
        #expect(throws: RegistryError.duplicateName(def: "test.add", name: "a")) { try NodeRegistry([def]) }
    }

    @Test func templateMayOnlyReferenceDeclaredNames() {
        var def = add
        def.body = .template("{out.out} = {in.a} + {in.zzz};")
        #expect(throws: RegistryError.unknownPlaceholder(def: "test.add", placeholder: "in.zzz")) {
            try NodeRegistry([def])
        }
    }

    @Test func genericNamesMustBeDeclared() {
        var def = add
        def.generics = [:]
        #expect(throws: RegistryError.undeclaredGeneric(def: "test.add", name: "T")) { try NodeRegistry([def]) }
    }

    @Test func variantsMustCoverEveryEnumCase() {
        var def = add
        def.params = [ParamDecl(name: "op", kind: .enumeration(["add", "sub"]), defaultValue: .enumCase("add"))]
        def.body = .variants(param: "op", ["add": "{out.out} = {in.a} + {in.b};"])
        #expect(throws: RegistryError.missingVariantCase(def: "test.add", case: "sub")) { try NodeRegistry([def]) }
    }

    @Test func variantsParamMustBeAnEnum() {
        var def = add
        def.params = [ParamDecl(name: "k", kind: .value(.float, range: nil), defaultValue: .float(0))]
        def.body = .variants(param: "k", [:])
        #expect(throws: RegistryError.variantsParamNotEnum(def: "test.add", param: "k")) { try NodeRegistry([def]) }
    }

    @Test func paramValueLiteralsAndTypes() {
        #expect(ParamValue.float(0.5).mslLiteral == "0.5")
        #expect(ParamValue.float3(.init(1, 2, 3)).mslLiteral == "float3(1.0, 2.0, 3.0)")
        #expect(ParamValue.int(7).mslLiteral == "7")
        #expect(ParamValue.bool(true).mslLiteral == "true")
        #expect(ParamValue.float2(.init(0, 0)).socketType == .float2)
        #expect(ParamValue.enumCase("add").socketType == nil)
        #expect(ParamValue.asset(nil).socketType == nil)
    }

    @Test func sysPlaceholdersMustNameASystemValue() {
        let ok = NodeDef(id: "t.ok", title: "ok", category: .input,
                         outputs: [SocketDecl(name: "o", type: .concrete(.float2))],
                         body: .template("{out.o} = {sys.uv} + {sys.mouse};"))
        #expect(throws: Never.self) { try NodeRegistry([ok]) }
        let bad = NodeDef(id: "t.bad", title: "bad", category: .input,
                          outputs: [SocketDecl(name: "o", type: .concrete(.float))],
                          body: .template("{out.o} = {sys.frame};"))
        #expect(throws: RegistryError.unknownPlaceholder(def: "t.bad", placeholder: "sys.frame")) { try NodeRegistry([bad]) }
    }

    @Test func paramsCanBeHiddenFromTheNodeBody() {
        let p = ParamDecl(name: "pos1", kind: .value(.float, range: 0...1), defaultValue: .float(0.5), showsInBody: false)
        #expect(!p.showsInBody)
        #expect(ParamDecl(name: "x", kind: .value(.float, range: nil), defaultValue: .float(0)).showsInBody)
        #expect(NodeDef(id: "t.dot", title: "Dot", category: .utility, body: .template(""), style: .dot).style == .dot)
    }
}
