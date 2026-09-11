// swift-tools-version: 5.9
import PackageDescription

// The AppKit app exists only on macOS. The manifest itself is Swift and
// evaluates on the build host, so the app target is appended only there —
// plain `swift build` / `swift test` work on Linux too (core + tray + CLI)
// without #if litter through the app sources.
var targets: [Target] = [
    // System zlib: the team envelope deflates plaintext before sealing
    // (docs/superpowers/specs/2026-09-05-team-design.md §3). Same bytes
    // on macOS, Linux and iOS; the Apple SDK and the swift docker image
    // both ship zlib.
    .systemLibrary(name: "CZlib", path: "Sources/CZlib", pkgConfig: "zlib",
                   providers: [.apt(["zlib1g-dev"])]),
    // Pure layer: models, feed decoding, supervisor state machine.
    // No AppKit import — everything here runs under `swift test`.
    .target(name: "InfinitusCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto"), "CZlib"],
            path: "Sources/InfinitusCore"),
    // Linux/Omarchy frontend: a Waybar custom module over the same core
    // (packaging/omarchy). The engine stays behind `swapd … --json`.
    .executableTarget(
        name: "InfinitusTray",
        dependencies: ["InfinitusCore"],
        path: "Sources/InfinitusTray"
    ),
    // Agent-facing control CLI: talks to the running app over its control
    // socket (ControlProtocol.swift); bundled into Infinitus.app/Contents/MacOS.
    // `infinitusctl team …` runs in-process, so the binary is built on every
    // platform; the socket-backed commands answer "needs the Mac app" elsewhere.
    .executableTarget(
        name: "InfinitusCLI",
        dependencies: ["InfinitusCore"],
        path: "Sources/InfinitusCLI"
    ),
    .testTarget(
        name: "InfinitusCoreTests",
        dependencies: ["InfinitusCore"],
        path: "Tests/InfinitusCoreTests",
        resources: [.copy("Fixtures")]
    ),
]
var products: [Product] = [
    .executable(name: "infinitus-tray", targets: ["InfinitusTray"]),
    .executable(name: "infinitusctl", targets: ["InfinitusCLI"]),
    .library(name: "InfinitusCore", targets: ["InfinitusCore"]),
]
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMinor(from: "3.15.1")),
]
#if os(macOS)
// Shared SwiftUI components (gauges, burn effects, theme colors) the
// phone app renders too — SwiftUI doesn't exist on Linux, so this stays
// fenced with the AppKit app target above.
targets.append(.target(
    name: "InfinitusUI",
    dependencies: ["InfinitusCore"],
    path: "Sources/InfinitusUI"
))
products.append(.library(name: "InfinitusUI", targets: ["InfinitusUI"]))
targets.append(.executableTarget(
    name: "Infinitus",
    dependencies: ["InfinitusCore", "InfinitusUI"],
    path: "Sources/Infinitus",
    // Debug only: lets InjectionIII swap top-level/struct functions
    // (docs/guides/hot-reload.md). Release links exactly as before.
    linkerSettings: [.unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug))]
))
#endif

let package = Package(
    name: "Infinitus",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
