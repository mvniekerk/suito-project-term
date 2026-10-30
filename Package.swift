// swift-tools-version: 6.0
import PackageDescription

// librio.a is a Rust staticlib: it needs the system libraries that Rust's std
// and rio's PTY/notifier layers depend on.
let rioLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("resolv"),
    .linkedLibrary("c++"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("CoreText"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("Security"),
    .linkedFramework("IOKit"),
    .linkedFramework("AppKit"),
]

let package = Package(
    name: "Suisto",
    // librio.a from the released xcframework is compiled against the macOS
    // 26.5 SDK; targeting older only produces linker warnings.
    platforms: [.macOS("26.5")],
    targets: [
        // Rio's embeddable terminal core: PTY + VT parser + grid + render state.
        // Prebuilt from rio v0.5.28; see Makefile `fetch-rio`. macos-arm64 only.
        .binaryTarget(
            name: "RioKit",
            path: "vendor/RioKit.xcframework"
        ),
        // Everything but the process entry point, so the tests can reach it
        // with @testable and no public annotations.
        .target(
            name: "SuistoKit",
            dependencies: ["RioKit"],
            path: "Sources/SuistoKit"
        ),
        .executableTarget(
            name: "Suisto",
            dependencies: ["SuistoKit"],
            path: "Sources/Suisto",
            linkerSettings: rioLinkerSettings
        ),
        // Headless check that RioKit links and the PTY round-trips.
        .executableTarget(
            name: "rio-smoke",
            dependencies: ["RioKit"],
            path: "Tools/smoke",
            linkerSettings: rioLinkerSettings
        ),
        .testTarget(
            name: "SuistoTests",
            // RioKit directly too: the renderer tests drive a real surface.
            dependencies: ["SuistoKit", "RioKit"],
            path: "Tests/SuistoTests",
            linkerSettings: rioLinkerSettings
        ),
    ]
)
