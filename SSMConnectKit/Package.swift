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
        .executable(name: "ssm-connect-proxy", targets: ["SSMConnectProxy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.7.13"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .executableTarget(name: "SSMConnectProxy", dependencies: ["SSMConnectKit"]),
        .target(
            name: "SSMConnectKit",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
                .product(name: "AWSEC2", package: "aws-sdk-swift"),
                .product(name: "AWSEC2InstanceConnect", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
            ],
            resources: [.copy("Resources/ThirdPartyNotices.txt")]
        ),
        .testTarget(
            name: "SSMConnectKitTests",
            dependencies: [
                "SSMConnectKit",
                // The tests construct AWS SDK response types directly. AWSClientRuntime is
                // explicit because the error-rendering tests build a real
                // `UnknownAWSHTTPServiceError` rather than a look-alike stub (#20).
                .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
                .product(name: "AWSEC2", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
            ]
        ),
    ]
)
