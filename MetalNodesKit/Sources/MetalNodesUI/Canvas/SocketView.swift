import SwiftUI
import MetalNodesCore

struct SocketAnchorKey: PreferenceKey {
    static let defaultValue: [SocketRef: CGPoint] = [:]
    static func reduce(value: inout [SocketRef: CGPoint], nextValue: () -> [SocketRef: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Circle for scalars/vectors, diamond for color, square for texture (spec §7.1).
struct SocketView: View {
    let type: SocketType
    static let size: CGFloat = 10

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
