#if os(Windows)
import Foundation
import WinSDK

/// The current user's SID and owner-only security descriptors: a protected DACL whose only
/// entry grants the current user full control, the Windows counterpart of mode 0600/0700.
enum WindowsSecurity {
    enum Failure: Error { case token, descriptor }

    /// The current user's SID, as bytes.
    static func currentUserSID() throws -> [UInt8] {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else { throw Failure.token }
        defer { CloseHandle(token) }
        var size: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard size > 0 else { throw Failure.token }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, size, &size) else { throw Failure.token }
        let sid = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid
        let length = Int(GetLengthSid(sid))
        return Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(sid), count: length))
    }

    /// Runs `body` with a security descriptor that grants only the current user full control,
    /// inherited by children when `container` is true.
    static func withOwnerOnlyDescriptor<T>(container: Bool, _ body: (UnsafeMutablePointer<SECURITY_ATTRIBUTES>) throws -> T) throws -> T {
        var sid = try currentUserSID()
        return try sid.withUnsafeMutableBytes { sidBytes in
            let sidPointer = sidBytes.baseAddress!
            var access = EXPLICIT_ACCESS_W()
            access.grfAccessPermissions = DWORD(GENERIC_ALL)
            access.grfAccessMode = SET_ACCESS
            access.grfInheritance = DWORD(container ? SUB_CONTAINERS_AND_OBJECTS_INHERIT : NO_INHERITANCE)
            access.Trustee.TrusteeForm = TRUSTEE_IS_SID
            access.Trustee.TrusteeType = TRUSTEE_IS_USER
            access.Trustee.ptstrName = sidPointer.assumingMemoryBound(to: WCHAR.self)
            var acl: PACL?
            guard SetEntriesInAclW(1, &access, nil, &acl) == ERROR_SUCCESS, let acl else { throw Failure.descriptor }
            defer { LocalFree(acl) }
            var descriptor = SECURITY_DESCRIPTOR()
            guard InitializeSecurityDescriptor(&descriptor, DWORD(SECURITY_DESCRIPTOR_REVISION)),
                  SetSecurityDescriptorOwner(&descriptor, sidPointer, false),
                  SetSecurityDescriptorDacl(&descriptor, true, acl, false),
                  SetSecurityDescriptorControl(&descriptor, SECURITY_DESCRIPTOR_CONTROL(SE_DACL_PROTECTED),
                                               SECURITY_DESCRIPTOR_CONTROL(SE_DACL_PROTECTED)) else { throw Failure.descriptor }
            return try withUnsafeMutablePointer(to: &descriptor) { pointer in
                var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                                                     lpSecurityDescriptor: UnsafeMutableRawPointer(pointer), bInheritHandle: false)
                return try body(&attributes)
            }
        }
    }

    /// Applies an owner-only protected DACL to an existing file or directory.
    static func restrictToOwner(_ path: String, container: Bool) throws {
        try withOwnerOnlyDescriptor(container: container) { attributes in
            let descriptor = attributes.pointee.lpSecurityDescriptor
            var present: WindowsBool = false, defaulted: WindowsBool = false
            var acl: PACL?
            guard GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted) else { throw Failure.descriptor }
            var owner: PSID?
            guard GetSecurityDescriptorOwner(descriptor, &owner, &defaulted) else { throw Failure.descriptor }
            let status = path.withCString(encodedAs: UTF16.self) { name in
                SetNamedSecurityInfoW(UnsafeMutablePointer(mutating: name), SE_FILE_OBJECT,
                                      SECURITY_INFORMATION(DACL_SECURITY_INFORMATION) | SECURITY_INFORMATION(PROTECTED_DACL_SECURITY_INFORMATION) | SECURITY_INFORMATION(OWNER_SECURITY_INFORMATION),
                                      owner, nil, acl, nil)
            }
            guard status == ERROR_SUCCESS else { throw Failure.descriptor }
        }
    }

    /// Whether the file is owned by the current user and its DACL allows no one else.
    static func isOwnerOnly(_ path: String) -> Bool {
        guard var user = try? currentUserSID() else { return false }
        var owner: PSID?, acl: PACL?, descriptor: PSECURITY_DESCRIPTOR?
        let status = path.withCString(encodedAs: UTF16.self) { name in
            GetNamedSecurityInfoW(name, SE_FILE_OBJECT, SECURITY_INFORMATION(OWNER_SECURITY_INFORMATION) | SECURITY_INFORMATION(DACL_SECURITY_INFORMATION),
                                  &owner, nil, &acl, nil, &descriptor)
        }
        guard status == ERROR_SUCCESS else { return false }
        defer { LocalFree(descriptor) }
        // A null DACL grants everyone access.
        guard let owner, let acl else { return false }
        return user.withUnsafeMutableBytes { userBytes -> Bool in
            let userSID = userBytes.baseAddress!
            guard EqualSid(owner, userSID) else { return false }
            var information = ACL_SIZE_INFORMATION()
            guard GetAclInformation(acl, &information, DWORD(MemoryLayout<ACL_SIZE_INFORMATION>.size), AclSizeInformation) else { return false }
            for index in 0..<information.AceCount {
                var ace: LPVOID?
                guard GetAce(acl, index, &ace), let ace else { return false }
                let header = ace.assumingMemoryBound(to: ACE_HEADER.self).pointee
                guard header.AceType == BYTE(ACCESS_ALLOWED_ACE_TYPE) else {
                    if header.AceType == BYTE(ACCESS_DENIED_ACE_TYPE) { continue }
                    return false // object or callback ACEs: not a plain owner-only DACL
                }
                let allowed = ace.assumingMemoryBound(to: ACCESS_ALLOWED_ACE.self)
                let sid = UnsafeMutableRawPointer(allowed).advanced(by: MemoryLayout<ACCESS_ALLOWED_ACE>.offset(of: \.SidStart)!)
                guard EqualSid(sid, userSID) else { return false }
            }
            return true
        }
    }
}
#endif
