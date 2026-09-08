import SwiftUI
import CoreGraphics
import MetalNodesCore

/// The inline editor for one parameter or unwired input.
struct ParamControl: View {
    let label: String
    let kind: ParamKind
    let value: ParamValue
    let onChange: (ParamValue) -> Void
    var onEditing: ((Bool) -> Void)? = nil
    /// The image well's thumbnail: already decoded and cached by the model, because this body runs
    /// on every keystroke and every preview tick.
    var image: CGImage? = nil
    /// What the well's chooser buttons run, with the source the button stands for. Nil where there
    /// is no chooser at all (the node body's compact well), which hides them.
    var onChooseImage: ((ImageSource) -> Void)? = nil

    @State private var draft = ""
    /// True between `onEditing?(true)` and `onEditing?(false)`, so a teardown can tell whether
    /// it still owes the close. Tracked separately from `focused` because `@FocusState` is
    /// reset by SwiftUI when the field leaves the hierarchy, without `onChange` observing it.
    @State private var editingSession = false
    @FocusState private var focused: Bool

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
            imageWell
        case .text(let multiline):
            textField(multiline)
        }
    }

    /// A code field. It commits on Return or focus loss rather than per keystroke: a half-typed
    /// formula is a compile error, and recompiling on every character would flood the canvas with
    /// red (spec §24.2).
    @ViewBuilder
    private func textField(_ multiline: Bool) -> some View {
        let current: String = { if case .text(let s) = value { return s } else { return "" } }()
        let field = TextField(label, text: $draft, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 3...12 : 1...1)
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            // NOT `.smartQuotesDisabled()`/`.smartDashesDisabled()` (fix round 1 asked for
            // these): neither exists in SwiftUI on macOS or iOS — grepped both platforms'
            // `SwiftUI.swiftinterface` for "smart", "quotes" and "dashes" and found no such
            // modifier, environment key, or `TextField` initializer parameter anywhere.
            // `smartQuotesType`/`smartDashesType` are `UITextInputTraits` on `UITextField`
            // directly; SwiftUI's `TextField` does not surface them, on either platform, and
            // suppressing them would need a hand-rolled `NSViewRepresentable`/
            // `UIViewRepresentable` wrapping the platform text field outright — out of scope for
            // this fix round. `.autocorrectionDisabled()` (below) is the one suppression that
            // exists and applies; a formula's real iPadOS hazard — `float3` capitalised,
            // identifiers "corrected" — is autocorrection/autocapitalisation, not smart
            // punctuation, and both of those are still disabled.
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { commitDraft() }
            .onChange(of: focused) { _, now in
                // The commit must land *inside* the transaction `onEditing?(true)` opened on
                // focus gain, so the whole edit — not just its snapshot — closes as one undo
                // step when `onEditing?(false)` below ends it. Committing after would leave the
                // transaction's snapshot equal to the still-uncommitted document, so
                // `endTransaction`'s own `commitUndo` would register nothing, and the actual
                // write would land as its own separate, untransacted step instead (Task 15 fix
                // round 1, MUST-FIX 7).
                if !now { commitDraft() }
                editingSession = now
                onEditing?(now)
            }
            .onDisappear {
                // A focused field torn down with its row — the node was deselected, deleted,
                // or the inspector switched to something else — loses focus without
                // `onChange(of: focused)` ever firing, so the transaction opened on focus gain
                // would stay open for the rest of the document's life: `EditorModel.undo()` is
                // a no-op while one is open, and every later edit performs without registering,
                // so ⌘Z is silently dead until a canvas drag's defensive reset happens to close
                // it (in-app checklist item 29, found 2026-09-08). Close it here, committing the
                // draft first, exactly as focus loss would have.
                guard editingSession else { return }
                editingSession = false
                commitDraft()
                onEditing?(false)
            }
            .focused($focused)
            .onAppear { draft = current }
            .onChange(of: current) { _, new in if !focused { draft = new } }

        if multiline {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(DraculaToken.muted.color)
                field
            }
        } else {
            // One row, like every other body control: `NodeGeometry.paramRows` counts a
            // single-line `.text` param as exactly one row, so it must actually draw as one — a
            // separate caption line above the field, as the multiline case has room for, would
            // silently understate the node's real height (Task 15 fix round 1, MUST-FIX 3).
            HStack(spacing: 4) {
                Text(label).font(.caption).frame(width: 46, alignment: .leading)
                field
            }
        }
    }

    private func commitDraft() {
        if case .text(let s) = value, s == draft { return }
        onChange(.text(draft))
    }

    /// The image well (spec §21.2): the imported image's thumbnail, a chooser to import another,
    /// "Clear" to unassign — an unassigned Texture Sample still renders, on the placeholder. The Mac
    /// has one open panel ("Choose…"); the iPad splits it into Photos and Files (spec §22.4).
    private var imageWell: some View {
        let assigned: Bool = { if case .asset(let a) = value { return a != nil } else { return false } }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            HStack(spacing: 8) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    if let choose = onChooseImage {
                        #if os(macOS)
                        Button("Choose…") { choose(.files) }
                        #else
                        Button("Photos…") { choose(.photos) }
                        Button("Files…") { choose(.files) }
                        #endif
                    }
                    Button("Clear") { onChange(.asset(nil)) }.disabled(!assigned)
                }
                .controlSize(.small)
            }
        }
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return shape
            .fill(DraculaToken.surface.color)
            .frame(width: 48, height: 48)
            .overlay { thumbnailContent.clipShape(shape) }
            .overlay { shape.stroke(DraculaToken.muted.color, lineWidth: 1) }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let image {
            // `decorative:` because the image is the parameter's value, not content to describe:
            // the well is already labelled, and an imported file has no alt text to offer.
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            Image(systemName: "photo").foregroundStyle(DraculaToken.muted.color)
        }
    }

    @ViewBuilder
    private func valueControl(_ type: SocketType, _ range: ClosedRange<Float>?) -> some View {
        switch type {
        case .float:
            let f: Float = { if case .float(let x) = value { return x } else { return 0 } }()
            HStack(spacing: 4) {
                Text(label).font(.caption).frame(width: 46, alignment: .leading)
                Slider(value: Binding(get: { f }, set: { onChange(.float($0)) }), in: range ?? -10...10,
                       onEditingChanged: { onEditing?($0) })
                    .controlSize(.mini)
                // Three digits and two decimals do not fit 36pt, and the node is a fixed 190 wide:
                // let the readout keep its one line and take the width it needs, out of the
                // slider's, rather than wrapping "215.41" onto two.
                Text(f.formatted(.number.precision(.fractionLength(2))))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 36, alignment: .trailing)
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
