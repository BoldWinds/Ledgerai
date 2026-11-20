// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LedgerCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(name: "LedgerCore", path: "Ledger/Core"),
        .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore"])
    ]
)
