// swift-tools-version: 6.0
import PackageDescription

// FixtureRecorder: records what the current aws-sdk-swift based code does, so
// SSMConnectAWSClient's parity tests can hold the replacement to it
// (cross-platform-client spec, AC-28). Package.resolved is a copy of the app's, so
// the recorder runs the exact SDK version the app ships. It is a development tool;
// nothing in the app depends on it.
let package = Package(
    name: "FixtureRecorder",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.7.62"),
        .package(url: "https://github.com/smithy-lang/smithy-swift", exact: "0.242.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.0"),
    ],
    targets: [
        .executableTarget(
            name: "FixtureRecorder",
            dependencies: [
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
                .product(name: "AWSEC2", package: "aws-sdk-swift"),
                .product(name: "AWSEC2InstanceConnect", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
                .product(name: "AWSSTS", package: "aws-sdk-swift"),
                .product(name: "SmithyIdentity", package: "smithy-swift"),
                .product(name: "SmithyHTTPAPI", package: "smithy-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
    ]
)
