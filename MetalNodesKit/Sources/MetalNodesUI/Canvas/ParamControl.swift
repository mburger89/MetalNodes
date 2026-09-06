import SwiftUI
import MetalNodesCore

/// The inline editor for one parameter or unwired input.
struct ParamControl: View {
    let label: String
    let kind: ParamKind
    let value: ParamValue
    let onChange: (ParamValue) -> Void

    var body: some View {
        switch kind {
        case .value(let type, let range):
            valueControl(type, range)
        case .enumeration(let cases):
            Picker(label, selection: Binding(
                get: { if case .enumCase(let c) = value { return c } else { return cases.first ?? "" } },
                set: { onChange(.enumCase($0)) })) {
                ForEach(cases, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.menu)
            .font(.caption)
        case .asset:
            Text(label).font(.caption).foregroundStyle(DraculaToken.muted.color)
        }
    }

    @ViewBuilder
    private func valueControl(_ type: SocketType, _ range: ClosedRange<Float>?) -> some View {
        switch type {
        case .float:
            let f: Float = { if case .float(let x) = value { return x } else { return 0 } }()
            HStack(spacing: 4) {
                Text(label).font(.caption).frame(width: 46, alignment: .leading)
                Slider(value: Binding(get: { f }, set: { onChange(.float($0)) }), in: range ?? -10...10)
                    .controlSize(.mini)
                Text(f.formatted(.number.precision(.fractionLength(2)))).font(.caption2.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
        case .int:
            let i: Int32 = { if case .int(let x) = value { return x } else { return 0 } }()
            Stepper("\(label): \(i)", value: Binding(get: { Int(i) }, set: { onChange(.int(Int32($0))) }),
                    in: Int(range?.lowerBound ?? -100)...Int(range?.upperBound ?? 100))
                .font(.caption)
        case .bool:
            let b: Bool = { if case .bool(let x) = value { return x } else { return false } }()
            Toggle(label, isOn: Binding(get: { b }, set: { onChange(.bool($0)) })).font(.caption).toggleStyle(.switch).controlSize(.mini)
        case .color, .float4:
            let v: SIMD4<Float> = { if case .float4(let x) = value { return x } else { return .init(1, 1, 1, 1) } }()
            ColorPicker(label, selection: Binding(
                get: { CGColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: CGFloat(v.w)) },
                set: { c in
                    var comps = (c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? c).components ?? [1, 1, 1, 1]
                    if comps.count == 2 { comps = [comps[0], comps[0], comps[0], comps[1]] }
                    while comps.count < 4 { comps.append(comps.count == 3 ? 1 : 0) }
                    onChange(.float4(.init(Float(comps[0]), Float(comps[1]), Float(comps[2]), Float(comps[3]))))
                }), supportsOpacity: true)
                .font(.caption)
        case .float2, .float3:
            let comps: [Float] = {
                switch value {
                case .float2(let x): [x.x, x.y]
                case .float3(let x): [x.x, x.y, x.z]
                case .float(let x): [x, x, x]
                default: [0, 0, 0]
                }
            }()
            let n = type.componentCount ?? 3
            HStack(spacing: 2) {
                Text(label).font(.caption).frame(width: 46, alignment: .leading)
                ForEach(0..<n, id: \.self) { i in
                    TextField("", value: Binding(
                        get: { i < comps.count ? comps[i] : 0 },
                        set: { x in
                            var c = Array(comps.prefix(n)) + Array(repeating: Float(0), count: max(0, n - comps.count))
                            c[i] = x
                            onChange(n == 2 ? .float2(.init(c[0], c[1])) : .float3(.init(c[0], c[1], c[2])))
                        }), format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).font(.caption2).frame(width: 44)
                }
            }
        case .texture:
            EmptyView()
        }
    }
}
