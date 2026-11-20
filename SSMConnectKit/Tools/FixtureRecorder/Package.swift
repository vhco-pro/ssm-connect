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
            ]
        ),
    ]
)
