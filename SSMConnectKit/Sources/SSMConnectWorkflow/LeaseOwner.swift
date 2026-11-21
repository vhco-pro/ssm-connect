import Foundation
import SSMConnectDomain
#if os(Windows)
import WinSDK
#endif

/// The build of SSM Connect this binary belongs to. The shells, helper and editor proxy of one
/// installation share it; the release jobs stamp it. A helper of another build is refused at
/// handshake, and a lease records its owner's build so a proxy of another build refuses new
/// channels (AC-17).
package enum InstalledBuild {
    package static let current = "dev"
}

/// The process that owns editor leases: the app on macOS, the helper on Windows and Linux.
/// `launchDate` is the process's start time, so a reused PID never matches.
package struct LeaseOwnerIdentity: Equatable, Sendable {
    package let pid: Int32
    package let launchDate: Date
    package let bundleID: String

    package init(pid: Int32, launchDate: Date, bundleID: String) {
        self.pid = pid
        self.launchDate = launchDate
        self.bundleID = bundleID
    }
}

/// Lease owner identity from the platform.
package protocol LeaseOwnerProbing: Sendable {
    /// This process as a lease owner, or nil when it cannot be identified.
    func current() -> LeaseOwnerIdentity?
    /// Whether the owner that wrote a lease is still running as the same process.
    func isActive(_ owner: LeaseOwnerIdentity) -> Bool
}

extension RemoteSSHLease {
    package var owner: LeaseOwnerIdentity {
        LeaseOwnerIdentity(pid: ownerPID, launchDate: ownerLaunchDate, bundleID: ownerBundleID)
    }

    /// Refuses a new channel through a proxy of a different build than the lease's owner, before
    /// any AWS call. A lease without a recorded build was written by an older build.
    package func requireSameBuild(_ build: String = InstalledBuild.current) throws {
        guard ownerBuild == build else { throw RemoteSSHError.updated }
    }
}

#if os(Linux) || os(Windows)
/// The helper as lease owner on Windows and Linux: its PID and the process start time the
/// kernel reports, so the proxy ends channels once that exact process is gone.
package struct ProcessLeaseOwner: LeaseOwnerProbing {
    package static let bundleID = "pro.vhco.ssm-connect.helper"

    package init() {}

    package func current() -> LeaseOwnerIdentity? {
        #if os(Windows)
        let pid = Int32(GetCurrentProcessId())
        #else
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        #endif
        return Self.startTime(of: pid).map { LeaseOwnerIdentity(pid: pid, launchDate: $0, bundleID: Self.bundleID) }
    }

    package func isActive(_ owner: LeaseOwnerIdentity) -> Bool {
        owner.bundleID == Self.bundleID && Self.startTime(of: owner.pid) == owner.launchDate
    }

    /// The process start time, or nil when no such process is running.
    static func startTime(of pid: Int32) -> Date? {
        #if os(Windows)
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(process) }
        var exitCode: DWORD = 0
        guard GetExitCodeProcess(process, &exitCode), exitCode == DWORD(STILL_ACTIVE) else { return nil }
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(process, &creation, &exit, &kernel, &user) else { return nil }
        let ticks = UInt64(creation.dwHighDateTime) << 32 | UInt64(creation.dwLowDateTime)
        // FILETIME counts 100 ns intervals since 1601-01-01.
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
        #else
        // Field 22 of /proc/<pid>/stat is the start time in clock ticks after boot; the comm
        // field before it may contain spaces, so count from the closing parenthesis.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let ticks = Double(fields[19]) else { return nil }
        // An opaque, stable identity: ticks after boot, not a wall-clock time.
        return Date(timeIntervalSinceReferenceDate: ticks)
        #endif
    }
}
#endif
