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
        // SSM Connect's own portable AWS client (cross-platform-client spec, AWS client).
        .package(path: "AWSClient"),
    ],
    targets: [
        .executableTarget(name: "SSMConnectProxy", dependencies: ["SSMConnectKit"]),
        // Models, validation, the profile document codec and typed errors, shared by every
        // desktop client. No macOS framework and no AWS SDK module: scripts/check-boundaries.sh
        // holds that line. Declarations the macOS code used are `package`, so the rest of this
        // package keeps its access and nothing new becomes public.
        .target(
            name: "SSMConnectDomain",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        // Authorization and the desktop, web and editor connection workflows, written against
        // injected ports. Like SSMConnectDomain, no macOS framework and no AWS SDK module; the
        // macOS implementations of its ports stay in the platform targets.
        .target(name: "SSMConnectWorkflow", dependencies: ["SSMConnectDomain"]),
        // The AWS boundary: SSM Connect's own client and the service ports built on it, shared by
        // every platform, and on macOS the aws-sdk-swift services until T36 switches it over.
        .target(
            name: "SSMConnectAWS",
            dependencies: [
                "SSMConnectDomain",
                "SSMConnectWorkflow",
                .product(name: "SSMConnectAWSClient", package: "AWSClient"),
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift", condition: .when(platforms: [.macOS])),
                .product(name: "AWSSSO", package: "aws-sdk-swift", condition: .when(platforms: [.macOS])),
                .product(name: "AWSEC2", package: "aws-sdk-swift", condition: .when(platforms: [.macOS])),
                .product(name: "AWSEC2InstanceConnect", package: "aws-sdk-swift", condition: .when(platforms: [.macOS])),
                .product(name: "AWSSSM", package: "aws-sdk-swift", condition: .when(platforms: [.macOS])),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "SSMConnectKit",
            dependencies: [
                "SSMConnectDomain",
                "SSMConnectWorkflow",
                "SSMConnectAWS",
                .product(name: "Yams", package: "Yams"),
                .product(name: "SSMConnectAWSClient", package: "AWSClient"),
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
                "SSMConnectDomain",
                "SSMConnectWorkflow",
                "SSMConnectAWS",
                // The tests construct AWS SDK response types directly. AWSClientRuntime is
                // explicit because the error-rendering tests build a real
                // `UnknownAWSHTTPServiceError` rather than a look-alike stub (#20).
                .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
                .product(name: "AWSEC2", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
                .product(name: "AWSEC2InstanceConnect", package: "aws-sdk-swift"),
                // Resolver tests inject the shared AWS client's transport.
                .product(name: "SSMConnectAWSClient", package: "AWSClient"),
            ]
        ),
    ]
)
