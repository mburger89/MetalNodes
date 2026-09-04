import Testing
import SwiftUI
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct DraculaThemeTests {
    @Test func officialPaletteHexValues() {
        #expect(DraculaToken.background.hex == 0x282A36)
        #expect(DraculaToken.surface.hex == 0x44475A)
        #expect(DraculaToken.foreground.hex == 0xF8F8F2)
        #expect(DraculaToken.muted.hex == 0x6272A4)
        #expect(DraculaToken.cyan.hex == 0x8BE9FD)
        #expect(DraculaToken.green.hex == 0x50FA7B)
        #expect(DraculaToken.orange.hex == 0xFFB86C)
        #expect(DraculaToken.pink.hex == 0xFF79C6)
        #expect(DraculaToken.purple.hex == 0xBD93F9)
        #expect(DraculaToken.red.hex == 0xFF5555)
        #expect(DraculaToken.yellow.hex == 0xF1FA8C)
    }

    @Test func redIsReservedForErrors() {
        for c in NodeCategory.allCases { #expect(DraculaTheme.token(for: c) != .red) }
        for t in SocketType.allCases { #expect(DraculaTheme.token(for: t) != .red) }
        for a in DraculaAccent.allCases { #expect(DraculaTheme.token(for: a) != .red) }
        #expect(DraculaTheme.error == .red)
    }

    @Test func socketTypesMatchSpecTable() {
        #expect(DraculaTheme.token(for: SocketType.float) == .cyan)
        #expect(DraculaTheme.token(for: SocketType.float2) == .green)
        #expect(DraculaTheme.token(for: SocketType.float3) == .purple)
        #expect(DraculaTheme.token(for: SocketType.float4) == .pink)
        #expect(DraculaTheme.token(for: SocketType.color) == .yellow)
        #expect(DraculaTheme.token(for: SocketType.int) == .orange)
        #expect(DraculaTheme.token(for: SocketType.bool) == .muted)
        #expect(DraculaTheme.token(for: SocketType.texture) == .foreground)
    }

    @Test func categoriesMatchSpecTable() {
        #expect(DraculaTheme.token(for: NodeCategory.input) == .cyan)
        #expect(DraculaTheme.token(for: NodeCategory.math) == .purple)
        #expect(DraculaTheme.token(for: NodeCategory.vector) == .green)
        #expect(DraculaTheme.token(for: NodeCategory.sdf) == .orange)
        #expect(DraculaTheme.token(for: NodeCategory.noise) == .pink)
        #expect(DraculaTheme.token(for: NodeCategory.color) == .yellow)
        #expect(DraculaTheme.token(for: NodeCategory.utility) == .muted)
        #expect(DraculaTheme.token(for: NodeCategory.output) == .foreground)
    }
}
