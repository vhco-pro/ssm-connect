// swift-tools-version: 6.0
import PackageDescription

// SSMConnectAWSClient: SSM Connect's own AWS client (cross-platform-client spec,
// "AWS client"). It depends on Foundation and swift-crypto only, so it builds and
// tests on macOS, Linux and Windows without aws-sdk-swift or aws-crt-swift. It is a
// separate package because SwiftPM on Linux builds every test target of a package
// into one bundle, and the main package's tests import AppKit.
let package = Package(
    name: "SSMConnectAWSClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SSMConnectAWSClient", targets: ["SSMConnectAWSClient"]),
    ],
    dependencies: [
        // The version the app's package graph already resolves (SSMConnectKit/Package.resolved).
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.0"),
    ],
    targets: [
        .target(
            name: "SSMConnectAWSClient",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "SSMConnectAWSClientTests",
            dependencies: ["SSMConnectAWSClient"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
