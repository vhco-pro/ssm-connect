# Helper feasibility spike (T4, T5)

A minimal helper for the cross-platform-client spec's first increment. It proves that the
shared Swift pieces run natively on Windows and Linux before broad extraction: SSO device
authorization and refresh, an AWS call, SSM StartSession with the Session Manager plugin,
and cleanup of the plugin it starts. It is not the production helper (T14, T15).

It is built from the app's own portable sources, copied in by the run scripts
(`SSMSessionResponse`, `AWSRegion`, `IdentityMapper`), and `SSMConnectKit/AWSClient`. The
plugin arguments follow `BundledPluginTunnel.pluginArguments`.

| Platform | Build |
| --- | --- |
| Linux | `spikes/helper-feasibility/run.sh` (a Swift 6.4 toolchain or the `swift:6.4.2-noble` container) |
| Windows | `powershell -ExecutionPolicy Bypass -File spikes\helper-feasibility\run.ps1` |

The helper reads one JSON command per line on stdin and answers with JSON events on stdout;
see the comment at the top of `Sources/HelperSpike/main.swift`. Credentials never leave the
process.
