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
    /// spelling `["x", "y", "z", "w"]` a second time, the same reasoning `UniformLayout.liveField
    /// (for:)`'s doc comment gives for not re-deriving `.float`-ness a second way: one table, read
    /// from both the codegen side and the inspector label that has to agree with it.
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
}
