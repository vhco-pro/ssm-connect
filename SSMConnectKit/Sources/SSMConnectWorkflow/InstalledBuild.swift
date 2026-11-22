/// The build of SSM Connect this binary belongs to. The shells, helper and editor proxy of one
/// installation share it. A helper of another build is refused at handshake, and a lease records
/// its owner's build so a proxy of another build refuses new channels (AC-17).
///
/// The build ID sits inside one string literal, `marker`, so it appears verbatim in each
/// executable's bytes, where `InstallationCheck` looks for it before a launch. The release builds
/// (`packaging/windows/Build-Release.ps1`) stamp the marker and the bundled plugin's SHA-256 here
/// and restore the file afterwards; keep each declaration on one line.
package enum InstalledBuild {
    package static let marker = "ssm-connect-build:dev;"
    package static let current = InstallationCheck.build(inMarker: marker)
    /// The SHA-256 of the plugin this build bundles; nil in development builds, which bundle none.
    package static let pluginSHA256: String? = nil
}
