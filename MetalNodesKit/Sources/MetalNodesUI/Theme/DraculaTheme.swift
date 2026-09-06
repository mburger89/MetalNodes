import SwiftUI
import MetalNodesCore

/// The official Dracula palette. The only file allowed to contain hex literals.
public enum DraculaToken: CaseIterable, Sendable {
    case background, surface, foreground, muted
    case cyan, green, orange, pink, purple, red, yellow

    public var hex: UInt32 {
        switch self {
        case .background: 0x282A36
        case .surface:    0x44475A
        case .foreground: 0xF8F8F2
        case .muted:      0x6272A4
        case .cyan:       0x8BE9FD
        case .green:      0x50FA7B
        case .orange:     0xFFB86C
        case .pink:       0xFF79C6
        case .purple:     0xBD93F9
        case .red:        0xFF5555
        case .yellow:     0xF1FA8C
        }
    }

    public var color: Color { Color(hex: hex) }
}

public enum DraculaTheme {
    /// Red is reserved for errors and used for nothing else (spec §12).
    public static let error: DraculaToken = .red
    /// Selection is an outline, not a hue.
    public static let selection: DraculaToken = .foreground
    public static let viewerFlag: DraculaToken = .green
    public static let wireDefault: DraculaToken = .muted
    public static let canvasGrid: Color = DraculaToken.surface.color.opacity(0.55)
    /// Code-panel comment colour (spec §21.5) — the official Dracula "Comment" hex already lives on `.muted`.
    public static let comment: DraculaToken = .muted
    /// Code-panel selected-line background (spec §21.5) — the official Dracula "Current Line" hex already lives on `.surface`.
    public static let currentLine: DraculaToken = .surface

    public static func token(for category: NodeCategory) -> DraculaToken {
        switch category {
        case .input: .cyan
        case .math: .purple
        case .vector: .green
        case .sdf: .orange
        case .noise: .pink
        case .color: .yellow
        case .utility: .muted
        case .group: .purple
        case .output: .foreground
        }
    }

    public static func token(for type: SocketType) -> DraculaToken {
        switch type {
        case .float: .cyan
        case .float2: .green
        case .float3: .purple
        case .float4: .pink
        case .color: .yellow
        case .int: .orange
        case .bool: .muted
        case .texture: .foreground
        }
    }

    public static func token(for accent: DraculaAccent) -> DraculaToken {
        switch accent {
        case .cyan: .cyan
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .purple: .purple
        case .yellow: .yellow
        case .muted: .muted
        }
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
