import SwiftUI

/// Canvas-space rects the touch overlay must hand back to SwiftUI (spec §22.2): param controls,
/// the ◉ viewer badge, comment resize handles. Collected exactly the way socket anchors are, in
/// the "canvas" coordinate space, so the overlay can test a touch against them after converting it
/// with the same transform the canvas draws with.
struct InteractiveRectKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reports this view's frame as a region the overlay must not swallow.
    func interactiveRect() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: InteractiveRectKey.self, value: [g.frame(in: .named("canvas"))])
        })
    }
}
