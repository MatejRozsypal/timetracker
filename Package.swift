// swift-tools-version:6.0
import PackageDescription

// No third-party dependencies on purpose: the app must build with the
// Command Line Tools alone (no Xcode, no macro plugins).
let package = Package(
    name: "oe-timelog",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OETimeLog",
            path: "Sources/OETimeLog",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
