// swift-tools-version: 6.2
// 6.2, а не 6.0: PlatformDescription узнаёт .v26 только с 6.2
// (замерено на первой сборке Фазы 0)
import PackageDescription

let package = Package(
    name: "ClipMouse",
    platforms: [.macOS(.v26)],
    targets: [
        // Вся логика — в библиотеке: иначе она недоступна для --selftest (§2)
        .target(name: "ClipMouseCore", path: "Sources/ClipMouseCore"),
        .executableTarget(
            name: "ClipMouse",
            dependencies: ["ClipMouseCore"],
            path: "Sources/ClipMouse"
        ),
    ],
    // Swift 6 strict concurrency — явно, не по умолчанию (§2)
    swiftLanguageModes: [.v6]
)
