import CoreGraphics
import MetalNodesCore

/// Pan/zoom math for the node canvas. Screen = canvas × zoom + pan.
public struct CanvasTransform: Equatable, Sendable {
    public static let minZoom: CGFloat = 0.15
    public static let maxZoom: CGFloat = 4

    public var pan: CGSize
    public var zoom: CGFloat

    public init(pan: CGSize = .zero, zoom: CGFloat = 1) {
        self.pan = pan
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    public init(camera: Camera) { self.init(pan: camera.pan, zoom: camera.zoom) }
    public var camera: Camera { Camera(pan: pan, zoom: zoom) }

    public func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.width, y: p.y * zoom + pan.height)
    }

    public func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    /// Multiplies zoom by `factor`, keeping the canvas point under `screenPoint` stationary.
    public mutating func zoom(by factor: CGFloat, around screenPoint: CGPoint) {
        let anchor = toCanvas(screenPoint)
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        pan = CGSize(width: screenPoint.x - anchor.x * zoom, height: screenPoint.y - anchor.y * zoom)
    }

    public mutating func pan(by delta: CGSize) {
        pan.width += delta.width
        pan.height += delta.height
    }

    public func visibleRect(viewport: CGSize) -> CGRect {
        let origin = toCanvas(.zero)
        return CGRect(x: origin.x, y: origin.y, width: viewport.width / zoom, height: viewport.height / zoom)
    }
}
