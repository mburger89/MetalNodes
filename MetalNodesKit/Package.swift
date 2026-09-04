// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MetalNodesKit",
    platforms: [.macOS("26.0"), .iOS("27.0")],
    products: [
        .library(name: "MetalNodesCore", targets: ["MetalNodesCore"]),
        .library(name: "MetalNodesRender", targets: ["MetalNodesRender"]),
        .library(name: "MetalNodesUI", targets: ["MetalNodesUI"]),
    ],
    targets: [
        .target(
            name: "MetalNodesCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MetalNodesRender",
            dependencies: ["MetalNodesCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MetalNodesUI",
            dependencies: ["MetalNodesCore", "MetalNodesRender"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "MetalNodesCoreTests", dependencies: ["MetalNodesCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MetalNodesRenderTests", dependencies: ["MetalNodesRender"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MetalNodesUITests", dependencies: ["MetalNodesUI"],
                    swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]),
    ]
)
