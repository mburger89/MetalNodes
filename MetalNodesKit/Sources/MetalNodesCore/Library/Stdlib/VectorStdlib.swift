import Foundation

extension MSLStdlib {
    static let vector: [MSLFunction] = [
        MSLFunction(name: "rotate2d", dependencies: [], source: """
        float2 mn_rotate2d(float2 v, float angle, float2 center) {
            float s = sin(angle), c = cos(angle);
            float2 d = v - center;
            return float2(c * d.x - s * d.y, s * d.x + c * d.y) + center;
        }
        """),
    ]
}
