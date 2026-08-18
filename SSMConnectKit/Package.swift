// swift-tools-version: 5.9
import PackageDescription

// SSMConnectKit — the app's code as a local Swift package. This is the single
// source of truth for SSM Connect's third-party dependencies (think go.mod), which
// is what makes Dependabot able to see + bump them. The Xcode app target
// (project.yml) is a thin @main shell that depends on this package and handles
// only the macOS .app bundling/signing that SwiftPM can't.
//
// The five targets below are the Phase 2 separation (spec §5.1/§5.2, MR-07). The
// boundary they create is the point: SSMConnectDomain and SSMConnectWorkflow depend
// on Foundation and each other and on nothing else, so AC-02 is enforced by the
// compiler rather than by review or by an import-scanning test. An `import AppKit`
// or `import AWSEC2` added to either of them fails the build.
//
// SSMConnectKit is the umbrella: it re-exports the layers and holds the composition
// root that wires the production adapters together. The app target depends on it
// alone, so the split is invisible from Xcode (AC-10).
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
        // Values, states, validation, typed domain errors. Foundation only, by construction.
        .target(name: "SSMConnectDomain"),

        // The connection algorithm, expressed against injected ports. Portable: this is the
        // target whose .NET twin is SSMConnect.Workflow, and the conformance fixtures pin them
        // to the same observable behavior.
        .target(name: "SSMConnectWorkflow", dependencies: ["SSMConnectDomain"]),

        // aws-sdk-swift adapters and SDK error mapping.
        .target(
            name: "SSMConnectAWS",
            dependencies: [
                "SSMConnectDomain",
                "SSMConnectWorkflow",
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
                .product(name: "AWSEC2", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
            ]
        ),

        // AppKit, notifications, clipboard, login item, plugin process, DCV, persistence.
        .target(name: "SSMConnectMacOS", dependencies: ["SSMConnectDomain", "SSMConnectWorkflow"]),

        // SwiftUI presentation. Observes workflow state and issues commands; holds no connection
        // rules of its own (§5.2).
        .target(
            name: "SSMConnectUI",
            dependencies: ["SSMConnectDomain", "SSMConnectWorkflow", "SSMConnectMacOS"]
        ),

        // Umbrella + composition root. The only target that knows every layer exists.
        .target(
            name: "SSMConnectKit",
            dependencies: [
                "SSMConnectDomain",
                "SSMConnectWorkflow",
                "SSMConnectAWS",
                "SSMConnectMacOS",
                "SSMConnectUI",
            ]
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
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
                .product(name: "AWSEC2", package: "aws-sdk-swift"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
            ]
        ),
    ]
)
