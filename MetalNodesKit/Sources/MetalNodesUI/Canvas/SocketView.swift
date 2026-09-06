import SwiftUI
import MetalNodesCore

struct SocketAnchorKey: PreferenceKey {
    static let defaultValue: [SocketRef: CGPoint] = [:]
    static func reduce(value: inout [SocketRef: CGPoint], nextValue: () -> [SocketRef: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Circle for scalars/vectors, diamond for color, square for texture (spec §7.1).
/// The visible dot is 10 pt; the hit area is 20 pt so wires are easy to grab.
struct SocketView: View {
    let type: SocketType
    var dimmed = false
    /// Narrowed on a `.dot` node, where a 20 pt grab would swallow the whole 24 pt body.
    var hitSize: CGFloat = SocketView.hitSize
    static let size: CGFloat = 10
    static let hitSize: CGFloat = 20

    var body: some View {
        let fill = DraculaTheme.token(for: type).color
        Group {
            switch type {
            case .color:
                Rectangle().fill(fill).rotationEffect(.degrees(45)).scaleEffect(0.8)
            case .texture:
                Rectangle().fill(fill)
            default:
                Circle().fill(fill)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .overlay {
            Group {
                switch type {
                case .color: Rectangle().stroke(DraculaToken.background.color, lineWidth: 1).rotationEffect(.degrees(45)).scaleEffect(0.8)
                case .texture: Rectangle().stroke(DraculaToken.background.color, lineWidth: 1)
                default: Circle().stroke(DraculaToken.background.color, lineWidth: 1)
                }
            }
        }
        .opacity(dimmed ? 0.3 : 1)
        .frame(width: hitSize, height: hitSize)
        .contentShape(Rectangle())
        .frame(width: Self.size, height: Self.size)   // report 10 pt to the row
    }
}

extension View {
    /// Reports this view's centre, in the "canvas" space, as the anchor for `ref`.
    func socketAnchor(_ ref: SocketRef) -> some View {
        background(GeometryReader { g in
            let f = g.frame(in: .named("canvas"))
            Color.clear.preference(key: SocketAnchorKey.self, value: [ref: CGPoint(x: f.midX, y: f.midY)])
        })
    }
}
