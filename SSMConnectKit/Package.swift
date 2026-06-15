// swift-tools-version: 5.9
import PackageDescription

// SSMConnectKit — the app's code as a local Swift package. This is the single
// source of truth for SSM Connect's third-party dependencies (think go.mod), which
// is what makes Dependabot able to see + bump them. The Xcode app target
// (project.yml) is a thin @main shell that depends on this package and handles
// only the macOS .app bundling/signing that SwiftPM can't.
let package = Package(
    name: "SSMConnectKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SSMConnectKit", targets: ["SSMConnectKit"]),
    ],
    dependencies: [
        // aws-sdk-swift — the only external dependency (spec §12.1).
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.7.13"),
    ],
    targets: [
        .target(
            name: "SSMConnectKit",
            dependencies: [
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
                .product(name: "AWSEC2", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "SSMConnectKitTests",
            dependencies: [
                "SSMConnectKit",
                // The tests construct AWS SDK response types directly.
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
                .product(name: "AWSEC2", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
            ]
        ),
    ]
)
