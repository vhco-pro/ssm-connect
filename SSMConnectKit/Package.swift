// swift-tools-version: 5.9
import PackageDescription

// SSMConnectKit — the app's code as a local Swift package. This is the single
// source of truth for SSM Connect's third-party dependencies (think go.mod), which
// is what makes Dependabot able to see + bump them. The Xcode app target
// (project.yml) is a thin @main shell that depends on this package and handles
// only the macOS .app bundling/signing that SwiftPM can't.
//
// The shared layers, the helper and the SSH proxy build on macOS, Windows and Linux. The macOS
// adapters, SwiftUI and the umbrella exist only when the manifest is evaluated on macOS. Every
// platform reaches AWS through SSM Connect's own client (AWSClient); no AWS SDK is linked.

var products: [Product] = [
    .executable(name: "SSMConnectHelper", targets: ["SSMConnectHelper"]),
    .executable(name: "ssm-connect-proxy", targets: ["SSMConnectProxy"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    // SSM Connect's own portable AWS client (cross-platform-client spec, AWS client).
    .package(path: "AWSClient"),
    // SHA-1 for the AWS CLI's SSO cache file names on every platform; the AWS client pins the same.
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.0"),
]

var awsDependencies: [Target.Dependency] = [
    "SSMConnectDomain",
    "SSMConnectWorkflow",
    .product(name: "SSMConnectAWSClient", package: "AWSClient"),
    .product(name: "Crypto", package: "swift-crypto"),
]

var helperCoreDependencies: [Target.Dependency] = [
    "SSMConnectHelperProtocol", "SSMConnectDomain", "SSMConnectWorkflow", "SSMConnectAWS",
    .product(name: "SSMConnectAWSClient", package: "AWSClient"),
    .product(name: "Crypto", package: "swift-crypto"),
]
#if os(Windows)
helperCoreDependencies.append("SSMConnectWindows")
#elseif os(Linux)
helperCoreDependencies.append("SSMConnectLinux")
#endif

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
    .target(name: "SSMConnectWorkflow", dependencies: [
        "SSMConnectDomain",
        // SHA-256 for the installation check of the bundled plugin.
        .product(name: "Crypto", package: "swift-crypto"),
    ]),
    // The helper protocol: framing, the build handshake, command admission, terminal results,
    // cancellation, heartbeats and events. Foundation only.
    .target(name: "SSMConnectHelperProtocol"),
    // The helper's runtime: the workflows composed from its services, and the command table that
    // maps each shell action to one of them. A library, so tests import it on every platform.
    .target(
        name: "SSMConnectHelperCore",
        dependencies: helperCoreDependencies
    ),
    // The Windows and Linux shells' private helper: the protocol over stdin/stdout, diagnostics
    // on stderr, exiting on stdin EOF.
    .executableTarget(
        name: "SSMConnectHelper",
        dependencies: ["SSMConnectHelperProtocol", "SSMConnectHelperCore", "SSMConnectWorkflow"]
    ),
    // The AWS boundary's client path; runs on macOS, Linux and Windows.
    .testTarget(name: "SSMConnectAWSTests", dependencies: [
        "SSMConnectAWS", "SSMConnectDomain", "SSMConnectWorkflow",
        .product(name: "SSMConnectAWSClient", package: "AWSClient"),
    ]),
    // The shared workflows' portable rules; runs on macOS, Linux and Windows.
    .testTarget(name: "SSMConnectWorkflowTests", dependencies: ["SSMConnectDomain", "SSMConnectWorkflow"]),
    // The helper protocol and executable, with fake ports; runs on macOS, Linux and Windows.
    .testTarget(
        name: "SSMConnectHelperTests",
        dependencies: ["SSMConnectHelperProtocol", "SSMConnectHelperCore", "SSMConnectHelper",
                       "SSMConnectDomain", "SSMConnectWorkflow"]
    ),
]

#if os(Windows)
targets += [
    // The core-side Windows adapters: per-user ACL files, the key-value store, tool discovery
    // and process launch, and browser discovery.
    .target(name: "SSMConnectWindows", dependencies: ["SSMConnectDomain", "SSMConnectWorkflow"]),
    .testTarget(name: "SSMConnectWindowsTests", dependencies: ["SSMConnectDomain", "SSMConnectWorkflow", "SSMConnectWindows"]),
]
#endif

#if os(Linux)
targets += [
    // The core-side Linux adapters: XDG paths, the key-value store, tool discovery and browser
    // discovery. User-only files live in SSMConnectWorkflow beside the Windows writer.
    .target(name: "SSMConnectLinux", dependencies: ["SSMConnectDomain", "SSMConnectWorkflow"]),
    .testTarget(name: "SSMConnectLinuxTests", dependencies: ["SSMConnectDomain", "SSMConnectWorkflow", "SSMConnectLinux"]),
]
#endif

#if os(macOS)
products += [
    .library(name: "SSMConnectKit", targets: ["SSMConnectKit"]),
]
targets += [
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
            "SSMConnectMacOS",
            "SSMConnectUI",
            // Resolver and sign-in tests inject the shared AWS client's transport.
            .product(name: "SSMConnectAWSClient", package: "AWSClient"),
        ],
        // Read from the source tree through #filePath, not bundled.
        exclude: ["Fixtures"]
    ),
]
#endif

// The AWS boundary: SSM Connect's own client and the service ports built on it, shared by
// every platform.
targets.append(.target(name: "SSMConnectAWS", dependencies: awsDependencies))

// The editor's SSH proxy: the macOS composition through the umbrella, the client services on
// Windows and Linux.
#if os(macOS)
targets.append(.executableTarget(name: "SSMConnectProxy", dependencies: ["SSMConnectKit"]))
#else
targets.append(.executableTarget(name: "SSMConnectProxy", dependencies: ["SSMConnectWorkflow", "SSMConnectAWS"]))
#endif

let package = Package(
    name: "SSMConnectKit",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
