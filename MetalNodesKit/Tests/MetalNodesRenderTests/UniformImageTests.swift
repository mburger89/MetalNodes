import Testing
import MetalNodesCore
@testable import MetalNodesRender

@Suite struct UniformImageTests {
    let n = NodeID()
    func path(_ p: String) -> ParamPath { ParamPath(node: n, param: p) }

    func readFloat(_ img: UniformImage, _ offset: Int) -> Float {
        img.bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }
    func readInt(_ img: UniformImage, _ offset: Int) -> Int32 {
        img.bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
    }

    @Test func writesFloatAtFieldOffset() {
        let layout = UniformLayoutBuilder.build([(path("a"), .float)])
        var img = UniformImage(layout: layout)
        let ok = img.set(.float(0.75), for: path("a"))
        #expect(ok)
        #expect(readFloat(img, layout.field(for: path("a"))!.offset) == 0.75)
        #expect(img.bytes.count == layout.totalSize)
    }

    @Test func scalarSplatsIntoFloat3Field() {
        let layout = UniformLayoutBuilder.build([(path("v"), .float3)])
        var img = UniformImage(layout: layout)
        img.set(.float(2), for: path("v"))
        let o = layout.field(for: path("v"))!.offset
        #expect(readFloat(img, o) == 2 && readFloat(img, o + 4) == 2 && readFloat(img, o + 8) == 2)
    }

    @Test func float3PadsToFloat4WithAlphaOne() {
        let layout = UniformLayoutBuilder.build([(path("c"), .color)])
        var img = UniformImage(layout: layout)
        img.set(.float3(.init(0.1, 0.2, 0.3)), for: path("c"))
        let o = layout.field(for: path("c"))!.offset
        #expect(readFloat(img, o + 12) == 1)
    }

    @Test func boolWritesInt() {
        let layout = UniformLayoutBuilder.build([(path("b"), .bool)])
        var img = UniformImage(layout: layout)
        img.set(.bool(true), for: path("b"))
        #expect(readInt(img, layout.field(for: path("b"))!.offset) == 1)
        img.set(.float(0), for: path("b"))
        #expect(readInt(img, layout.field(for: path("b"))!.offset) == 0)
    }

    @Test func intFieldToleratesNaNAndHugeValues() {
        let layout = UniformLayoutBuilder.build([(path("i"), .int)])
        var img = UniformImage(layout: layout)
        img.set(.float(.nan), for: path("i"))
        #expect(readInt(img, layout.field(for: path("i"))!.offset) == 0)
        img.set(.float(1e20), for: path("i"))
        #expect(readInt(img, layout.field(for: path("i"))!.offset) == Int32.max)
    }

    @Test func unknownPathReturnsFalse() {
        var img = UniformImage(layout: UniformLayoutBuilder.build([]))
        let ok = img.set(.float(1), for: path("nope"))
        #expect(ok == false)
    }

    @Test func reservedFieldsAreWritten() {
        let layout = UniformLayoutBuilder.build([])
        var img = UniformImage(layout: layout)
        img.setReserved(time: 3.5, resolution: .init(640, 480), mouse: .init(1, 2))
        #expect(readFloat(img, layout.reserved("time").offset) == 3.5)
        #expect(readFloat(img, layout.reserved("resolution").offset + 4) == 480)
        #expect(readFloat(img, layout.reserved("mouse").offset) == 1)
    }

    @Test func rebuildReadsDocumentValuesAndDefaults() throws {
        let doc = ShaderDocument.sample()
        let shader = try ShaderGenerator.generate(doc)
        let img = UniformImage.rebuild(layout: shader.layout, document: doc, registry: .builtin)
        let speed = doc.root.nodes.values.first { $0.kind == .builtin("input.float") }!
        let noise = doc.root.nodes.values.first { $0.kind == .builtin("noise.value") }!
        let tint = doc.root.nodes.values.first { $0.kind == .builtin("input.color") }!
        #expect(readFloat(img, shader.layout.field(for: ParamPath(node: speed.id, param: "value"))!.offset) == 0.25)
        #expect(readFloat(img, shader.layout.field(for: ParamPath(node: noise.id, param: "scale"))!.offset) == 6)
        #expect(readFloat(img, shader.layout.field(for: ParamPath(node: tint.id, param: "value"))!.offset + 12) == 1)
    }

    @Test func rebuildFillsSlotsInsideDefinitionsAndPerInstanceInputs() throws {
        let doc = ShaderDocument.sampleWithGroup()
        let s = try ShaderGenerator.generate(doc)
        let img = UniformImage.rebuild(layout: s.layout, document: doc, registry: .builtin)
        // Every user slot has a node somewhere in the document.
        for f in s.layout.fields { if let p = f.path { #expect(doc.node(p.instancePath[0]) != nil) } }
        #expect(img.bytes.count == s.layout.totalSize)
    }

    @Test func viewerRangeWritesOnlyWhenTheLayoutHasIt() {
        var plain = UniformImage(layout: UniformLayoutBuilder.build([]))
        plain.setViewerRange(0.2...0.8)                       // must not trap
        var viewer = UniformImage(layout: UniformLayoutBuilder.build([], reserved: UniformLayoutBuilder.viewerReserved))
        viewer.setViewerRange(0.25...0.75)
        let lo = viewer.layout.reserved("viewerMin").offset, hi = viewer.layout.reserved("viewerMax").offset
        #expect(viewer.bytes[lo..<lo + 4].withUnsafeBytes { $0.load(as: Float.self) } == 0.25)
        #expect(viewer.bytes[hi..<hi + 4].withUnsafeBytes { $0.load(as: Float.self) } == 0.75)
    }
}
