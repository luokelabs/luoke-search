// swift-tools-version: 6.2
import PackageDescription

// 螺壳搜索 (luoke-search): macOS only, 26.2 and later. No models here: vectors come from luoke-core's
// `luoke-search.embed` task over its socket (top-level ADR 0018).
let package = Package(
    name: "LuokeSearch",
    platforms: [.macOS("26.2")],
    products: [
        .executable(name: "luoke-search", targets: ["luoke-search"]),
        .library(name: "LuokeSearchKit", targets: ["LuokeSearchKit"]),
    ],
    targets: [
        // The engine: where the index lives, what to read and skip, reading files, the index store, search.
        .target(name: "LuokeSearchKit"),
        // The command line: index / search / status (open / settings / eval / mcp come in later blocks).
        .executableTarget(name: "luoke-search", dependencies: ["LuokeSearchKit"]),
        .testTarget(name: "LuokeSearchKitTests", dependencies: ["LuokeSearchKit"]),
    ]
)
