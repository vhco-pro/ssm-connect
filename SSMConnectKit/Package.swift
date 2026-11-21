// swift-tools-version: 5.9
import PackageDescription

// SSMConnectKit — the app's code as a local Swift package. This is the single
// source of truth for SSM Connect's third-party dependencies (think go.mod), which
// is what makes Dependabot able to see + bump them. The Xcode app target
// (project.yml) is a thin @main shell that depends on this package and handles
// only the macOS .app bundling/signing that SwiftPM can't.
//
// The shared layers and the helper build on macOS, Windows and Linux. The macOS adapters,
// SwiftUI, the umbrella, the SSH proxy and aws-sdk-swift (until T36) exist only when the
// manifest is evaluated on macOS, so `swift build` and `swift test` work on the other two.

let sdkProducts = ["AWSSSOOIDC", "AWSSSO", "AWSEC2", "AWSEC2InstanceConnect", "AWSSSM", "AWSSecretsManager"]

var products: [Product] = [
    .executable(name: "SSMConnectHelper", targets: ["SSMConnectHelper"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    // SSM Connect's own portable AWS client (cross-platform-client spec, AWS client).
    .package(path: "AWSClient"),
]

var awsDependencies: [Target.Dependency] = [
    "SSMConnectDomain",
    "SSMConnectWorkflow",
    .product(name: "SSMConnectAWSClient", package: "AWSClient"),
]

var targets: [Target] = [
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
    // platform implementations of its ports stay in the platform targets.
    .target(name: "SSMConnectWorkflow", dependencies: ["SSMConnectDomain"]),
    // The helper protocol: framing, the build handshake, command admission, terminal results,
    // cancellation, heartbeats and events. Foundation only.
    .target(name: "SSMConnectHelperProtocol"),
    // The Windows and Linux shells' private helper: the protocol over stdin/stdout, diagnostics
    // on stderr, exiting on stdin EOF.
    .executableTarget(
        name: "SSMConnectHelper",
        dependencies: ["SSMConnectHelperProtocol", "SSMConnectDomain", "SSMConnectWorkflow", "SSMConnectAWS"]
    ),
    // The helper protocol and executable, with fake ports; runs on macOS, Linux and Windows.
    .testTarget(
        name: "SSMConnectHelperTests",
        dependencies: ["SSMConnectHelperProtocol", "SSMConnectHelper"]
    ),
]

#if os(macOS)
products += [
    .library(name: "SSMConnectKit", targets: ["SSMConnectKit"]),
    .executable(name: "ssm-connect-proxy", targets: ["SSMConnectProxy"]),
]
dependencies.append(.package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.7.13"))
// On macOS the AWS boundary also holds the aws-sdk-swift services until T36 switches it over.
awsDependencies += sdkProducts.map { .product(name: $0, package: "aws-sdk-swift") }
targets += [
    .executableTarget(name: "SSMConnectProxy", dependencies: ["SSMConnectKit"]),
    // The macOS platform adapters: AppKit, persistence, DCV, the plugin and SSH processes,
    // browsers and editors.
    .target(
        name: "SSMConnectMacOS",
        dependencies: ["SSMConnectDomain", "SSMConnectWorkflow", "SSMConnectAWS"]
    ),
    // The macOS SwiftUI presentation: it observes workflow state and issues commands, and
    // holds no connection rules of its own.
    .target(
        name: "SSMConnectUI",
        dependencies: ["SSMConnectDomain", "SSMConnectWorkflow", "SSMConnectMacOS"]
    ),
    // The umbrella: re-exports the layers and holds the composition root that wires the
    // macOS adapters and AWS services into the workflows.
    .target(
        name: "SSMConnectKit",
        dependencies: [
            "SSMConnectDomain",
            "SSMConnectWorkflow",
            "SSMConnectAWS",
            "SSMConnectMacOS",
            "SSMConnectUI",
            .product(name: "Yams", package: "Yams"),
            .product(name: "SSMConnectAWSClient", package: "AWSClient"),
        ] + sdkProducts.map { .product(name: $0, package: "aws-sdk-swift") },
        resources: [.copy("Resources/ThirdPartyNotices.txt")]
    ),
    .testTarget(
        name: "SSMConnectKitTests",
        dependencies: [
            "SSMConnectKit",
            "SSMConnectDomain",
            "SSMConnectWorkflow",
            "SSMConnectAWS",
            "SSMConnectMacOS",
            "SSMConnectUI",
            // The tests construct AWS SDK response types directly. AWSClientRuntime is
            // explicit because the error-rendering tests build a real
            // `UnknownAWSHTTPServiceError` rather than a look-alike stub (#20).
            .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
            // Resolver tests inject the shared AWS client's transport.
            .product(name: "SSMConnectAWSClient", package: "AWSClient"),
        ] + sdkProducts.map { .product(name: $0, package: "aws-sdk-swift") },
        // Read from the source tree through #filePath, not bundled.
        exclude: ["Fixtures"]
    ),
]
#endif

// The AWS boundary: SSM Connect's own client and the service ports built on it, shared by
// every platform.
targets.append(.target(name: "SSMConnectAWS", dependencies: awsDependencies))

let package = Package(
    name: "SSMConnectKit",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
