/// `SSMConnectKit` is the umbrella over the Phase 2 layer split (spec §5.1, MR-07).
///
/// The layers exist to give the portable boundary a compiler barrier: `SSMConnectDomain` and
/// `SSMConnectWorkflow` cannot import AppKit, SwiftUI, or an AWS SDK because their targets do not
/// link them. That barrier is for the code inside the package. It is not something the app shell
/// should have to think about, so this target re-exports all five layers and the shell keeps its
/// single `import SSMConnectKit` (AC-10 — the app stays independently buildable throughout).
@_exported import SSMConnectDomain
@_exported import SSMConnectWorkflow
@_exported import SSMConnectAWS
@_exported import SSMConnectMacOS
@_exported import SSMConnectUI
