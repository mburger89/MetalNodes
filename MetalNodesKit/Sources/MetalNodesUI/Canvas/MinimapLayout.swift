import CoreGraphics

/// Pure geometry for the minimap overlay (spec §21.6): no view dependencies, so it is testable on
/// its own. Fits `graphBounds ∪ viewport` into `size` with `padding` pt of margin on every side,
/// aspect-preserving and centred on whichever axis has room to spare.
struct MinimapLayout: Equatable {
    static let padding: CGFloat = 8

    let size: CGSize
    let scale: CGFloat
    /// Where canvas-space `(0, 0)` lands in map space; `mapRect`/`canvasPoint` are this plus/minus
    /// a `scale` multiply, so the two are exact inverses of each other.
    private let translation: CGPoint

    init(size: CGSize = CGSize(width: 180, height: 120), graphBounds: CGRect, viewport: CGRect) {
        self.size = size
        let union = graphBounds.union(viewport)
        let availableWidth = max(size.width - 2 * Self.padding, 1)
        let availableHeight = max(size.height - 2 * Self.padding, 1)
        let unionWidth = max(union.width, 1)
        let unionHeight = max(union.height, 1)
        let scale = min(availableWidth / unionWidth, availableHeight / unionHeight)
        self.scale = scale
        let contentWidth = union.width * scale
        let contentHeight = union.height * scale
        self.translation = CGPoint(x: (size.width - contentWidth) / 2 - union.minX * scale,
                                    y: (size.height - contentHeight) / 2 - union.minY * scale)
    }

    /// `canvasRect` mapped into the minimap's coordinate space.
    func mapRect(_ canvasRect: CGRect) -> CGRect {
        CGRect(x: canvasRect.minX * scale + translation.x, y: canvasRect.minY * scale + translation.y,
               width: canvasRect.width * scale, height: canvasRect.height * scale)
    }

    /// The canvas point a minimap-space point corresponds to — the inverse of `mapRect`'s origin,
    /// used to turn a click or drag on the map into where the canvas should centre.
    func canvasPoint(_ mapPoint: CGPoint) -> CGPoint {
        CGPoint(x: (mapPoint.x - translation.x) / scale, y: (mapPoint.y - translation.y) / scale)
    }
}
