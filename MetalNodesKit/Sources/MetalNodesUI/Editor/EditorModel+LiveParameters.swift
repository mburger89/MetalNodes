import Foundation
import MetalNodesCore

/// Marking a float parameter live (spec §24.6, Task 18). `DocumentSettings.liveParameters` and its
/// export spelling (`EmitEnvironment.liveParameterComponents`, `MaterialExport`) predate this file —
/// this is the one place anything in the app actually sets the setting.
extension EditorModel {
    /// A `CustomMaterial` exposes exactly one `float4` (spec §23.6) — four floats, not five.
    static let liveParameterLimit = 4

    /// `custom_parameter()`'s component letter for a live parameter at `index`, `nil` past the
    /// fourth — forwards to `EmitEnvironment.liveParameterComponents` (spec §24.6) rather than
    /// spelling `["x", "y", "z", "w"]` a second time. That's a smaller instance of the same category
    /// of bug `UniformLayout.liveField(for:)`'s doc comment describes for a different fact — there,
    /// two independent spellings of "is this live path a float" drifted apart once already
    /// (`vector.dot`, fix round 2); here it would be two independent spellings of the same
    /// four-letter table, not a predicate — but the fix is the same shape: one source, every reader
    /// (the codegen side and this inspector label) reads from it rather than repeating it.
    ///
    /// Bounds-checked rather than a bare subscript: `DocumentSettings.liveParameters` carries no cap
    /// of its own — a hand-edited or migrated document can decode a fifth (or fifteenth) entry
    /// intact, and `MaterialValidation`'s rule 6 is what refuses that, as a diagnostic, not the
    /// decoder or this accessor. `MaterialExport.component(_:)` (private to that file) already
    /// guards the same lookup with `indices.contains`; this mirrors it so the settings pane the user
    /// sees *first*, before any diagnostic has a chance to render, can't trap on `Array.subscript`
    /// just from opening such a document (`liveParametersSection` calls this for every entry,
    /// unconditionally, and `documentSettings` is what an empty selection renders at the root).
    static func liveParameterComponent(_ index: Int) -> String? {
        EmitEnvironment.liveParameterComponents.indices.contains(index) ? EmitEnvironment.liveParameterComponents[index] : nil
    }

    /// This path's position in `document.settings.liveParameters`, if it is marked — the component
    /// letter beside the control, and what tells the toggle whether it is on.
    public func liveParameterIndex(of path: ParamPath) -> Int? {
        document.settings.liveParameters.firstIndex(of: path)
    }

    /// Marks or unmarks one float parameter as live. Returns `false` — with a notice — when the
    /// `float4` a `CustomMaterial` exposes is already full (spec §23.6, §24.6).
    @discardableResult
    public func toggleLiveParameter(_ path: ParamPath) -> Bool {
        var s = document.settings
        if let i = s.liveParameters.firstIndex(of: path) {
            s.liveParameters.remove(at: i)
        } else {
            guard s.liveParameters.count < Self.liveParameterLimit else {
                showNotice("A material exposes four live values; unmark one first")
                return false
            }
            s.liveParameters.append(path)
        }
        apply(.setSettings(s))
        return true
    }

    // MARK: Whether the "Live" control offers/warns — pulled out of `InspectorView` (fix round 2)
    // so a test can reach them. Both are pure functions of their arguments — no `EditorModel`
    // instance state — kept as `static` on `EditorModel` rather than free functions or a new type
    // because the rest of this file's readers (`liveParameterComponent`, `toggleLiveParameter`) are
    // exactly the vocabulary these two decisions are phrased in, and `InspectorView` already imports
    // `MetalNodesUI` to reach the instance API next to them.

    /// Whether a declared value param may be marked live (spec §24.6): a `CustomMaterial`'s `float4`
    /// holds exactly one float per component, so only a param whose kind is concretely `.float`
    /// qualifies — never an enum, asset, or text param, and never an unwired input socket's own
    /// fallback control (that's the sibling overload below).
    ///
    /// `ParamKind.value` carries a `SocketType`, which has no `.generic` case at all — a declared
    /// param's type is exactly what its `kind` says, always, unlike an input socket's `TypeRef`
    /// (below). So checking `decl.kind` directly is both simpler and correct here; there's no
    /// resolved-vs-declared question for this overload to get wrong.
    static func isLiveable(_ decl: ParamDecl) -> Bool {
        if case .value(.float, _) = decl.kind { return true }
        return false
    }

    /// The input-socket sibling of `isLiveable(_:)` above, for an *unwired* input's own fallback
    /// control (`InspectorView.builtinPane`'s `else if case .value` branch, which already computes
    /// `resolvedType` the same way to pick the control's own slider type).
    ///
    /// An input's declared type can be `.generic` (`vector.length`'s `v: .generic("T")`, defaulting
    /// to `.float2`; `vector.dot`'s `a`, defaulting to `.float` but resolving to `.float3` once `b`
    /// is wired — `MaterialValidation.fieldType`'s doc comment). Where the resolved type is already
    /// known, trust it exactly: it is the very type the emitter requests a uniform with, so a
    /// `.concrete(.float)` input that later resolves generically-in-context still reads correctly,
    /// and a `.generic` input that resolves to `.float` is offered once resolution says so — a
    /// deliberate widening past "generics are never offered": it's sound because it reads the
    /// emitter's own resolved type, never the lossy `concreteOrFloat` fallback described next.
    ///
    /// Only while resolution is pending (`resolvedType` is `nil` — no compile has landed yet, or one
    /// is mid-debounce) does this fall back to the *declared* type — and then only for
    /// `.concrete(.float)`, never `.generic`: `TypeRef.concreteOrFloat` (the control's own
    /// pending-resolution fallback for picking a slider type) maps every generic case to `.float`
    /// regardless of what the socket actually defaults to, which is exactly the trap excluding
    /// sockets altogether was meant to avoid in this task's first round. A generic socket is simply
    /// not offered until a resolved type says it is float; a `.concrete(.float)` socket is offered
    /// immediately, since its declared and resolved types can never disagree.
    static func isLiveable(_ decl: SocketDecl, resolvedType: SocketType?) -> Bool {
        if let resolvedType { return resolvedType == .float }
        if case .concrete(.float) = decl.type { return true }
        return false
    }

    /// Whether `path` is read as a live component of `layout` — the last successfully compiled
    /// program's `UniformLayout`, or `nil` before any compile has landed.
    ///
    /// `isLiveable` (above) only judges a control's own declared/resolved type; it says nothing
    /// about whether the node behind it is wired into the material at all. A path can be perfectly
    /// liveable and still unreachable — its node exists and is a float, but nothing feeds the
    /// terminal from it — and `bakedUniforms`/`MaterialExport.liveParameters` both quietly skip such
    /// a path rather than emit a mistyped read (`UniformLayout.liveField(for:)` is the shared
    /// predicate both call; see its doc comment). Without this check the toggle would show the mark
    /// "on" with a component letter that never appears anywhere in the `.metal`, the header, or the
    /// Swift snippet — the reader writes to `.x` from Swift and nothing animates, with nothing in
    /// the inspector saying why.
    ///
    /// Deliberately a *third*, read-only caller of `liveField(for:)` — not a re-derivation of it, and
    /// not a change to either of its two existing callers (`EmitEnvironment.bakedUniforms`,
    /// `MaterialExport.liveParameters`, both untouched). Takes the layout as a parameter rather than
    /// reaching for `EditorModel`'s own `preview` state, so it stays a pure function of "this path,
    /// this layout" that a test can call directly against a layout built the same way
    /// `LiveParametersTests` already builds one (`ShaderGenerator.generate(doc, target:
    /// .realityKit).layout`) — no compiler, no `MTLDevice`, no `EditorModel` instance required.
    ///
    /// `layout == nil` (no compile has landed yet) answers `true` — no warning: nothing has
    /// contradicted the mark yet, and a document that has never finished a first compile has bigger
    /// problems than this warning.
    static func isLiveParameterReachable(_ path: ParamPath, in layout: UniformLayout?) -> Bool {
        guard let layout else { return true }
        return layout.liveField(for: path) != nil
    }
}
