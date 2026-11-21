/// The build of SSM Connect this binary belongs to. The shells, helper and editor proxy of one
/// installation share it. A helper of another build is refused at handshake, and a lease records
/// its owner's build so a proxy of another build refuses new channels (AC-17).
///
/// The Windows release build (`packaging/windows/Build-Release.ps1`) stamps this file's value for
/// the build and restores it afterwards, and passes the same value to the shell; keep the
/// declaration on one line.
package enum InstalledBuild {
    package static let current = "dev"
}
