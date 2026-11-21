// swift-tools-version: 6.0
import PackageDescription

// T4 feasibility helper (cross-platform-client spec): the shared Swift pieces a Windows or
// Linux helper needs, run natively. It is a spike, not the production helper (T14/T15).
// run.sh and run.ps1 copy the reused app sources into Sources/HelperSpike/Reused first.
let package = Package(
    name: "HelperSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../SSMConnectKit/AWSClient"),
    ],
    targets: [
        .executableTarget(
            name: "HelperSpike",
            dependencies: [.product(name: "SSMConnectAWSClient", package: "AWSClient")]
        ),
    ]
)
