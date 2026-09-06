import SwiftUI

/// `Shader › Fbm › Turbulence` above the canvas (spec §20.8). Always visible — at the root it is
/// a single "Shader" segment — so entering or leaving a definition never shifts the canvas.
struct BreadcrumbBar: View {
    let model: EditorModel

    static let height: CGFloat = 24

    var body: some View {
        let crumbs = model.breadcrumb
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, crumb in
                if i > 0 {
                    Text("›").font(.caption).foregroundStyle(DraculaToken.muted.color)
                }
                let isLast = i == crumbs.count - 1
                // The crumb for the graph already being edited is a label, not a button: clicking
                // it would pop to where we already are and clear the selection for nothing.
                if isLast {
                    Text(crumb.title)
                        .font(.caption.bold())
                        .foregroundStyle(DraculaToken.foreground.color)
                        .lineLimit(1)
                } else {
                    Button(crumb.title) { model.popToLevel(crumb.level) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(DraculaToken.muted.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DraculaToken.surface.color)
    }
}
