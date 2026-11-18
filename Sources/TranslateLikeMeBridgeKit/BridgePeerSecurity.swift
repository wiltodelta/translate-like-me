import Darwin
import Foundation
import os
import Security

private let securityLog = Logger.app("bridge")

public enum BridgePeerPolicy: Sendable, Equatable {
    case teamID(String, allowedDevIdentifiers: Set<String>)
    case sameUserOnly

    public static var production: Self {
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        let devIDs: Set<String> = isDev
            ? [BridgeConfig.directDevBundleID, BridgeConfig.masDevBundleID, BridgeConfig.bridgeDevBundleID]
            : []
        return .teamID(BridgeConfig.teamID, allowedDevIdentifiers: devIDs)
    }
}

public enum BridgePeerSecurity {
    public static func verifyPeer(socket fd: Int32, policy: BridgePeerPolicy,
                                  isServerVerifyingClient: Bool = true) -> Bool {
        guard verifySameUser(socket: fd) else {
            securityLog.error("Rejected bridge peer: UID mismatch")
            return false
        }
        switch policy {
        case .sameUserOnly:
            return true
        case .teamID(let teamID, let allowedDevIdentifiers):
            guard var token = peerAuditToken(socket: fd) else {
                securityLog.error("Rejected bridge peer: missing audit token")
                return false
            }
            let attributes = [
                kSecGuestAttributeAudit: Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
            ] as CFDictionary
            var guest: SecCode?
            let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
            guard status == errSecSuccess, let guest else {
                // Inside App Sandbox, SecCodeCopyGuestWithAttributes cannot read a
                // Bridge bundle located in a TCC-protected folder (such as Downloads
                // or Documents), whereas the server is unsandboxed and always verifies
                // the client's full Team ID signature, and Seatbelt restricts binding
                // inside Group Containers/<TeamID>.* to Team-entitled processes.
                if !isServerVerifyingClient {
                    return true
                }
                securityLog.error("Rejected bridge peer: SecCodeCopyGuestWithAttributes failed (\(status))")
                return false
            }
            if matchesTeamRequirement(guest: guest, teamID: teamID) {
                return true
            }
            if !allowedDevIdentifiers.isEmpty, matchesIdentifier(guest: guest, in: allowedDevIdentifiers) {
                return true
            }
            securityLog.error("Rejected bridge peer: code signature did not match team \(teamID, privacy: .public)")
            return false
        }
    }

    private static func verifySameUser(socket fd: Int32) -> Bool {
        var cred = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &length) == 0,
              length == socklen_t(MemoryLayout<xucred>.size) else {
            return false
        }
        return cred.cr_uid == getuid()
    }

    private static func peerAuditToken(socket fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return nil
        }
        return token
    }

    private static func matchesTeamRequirement(guest: SecCode, teamID: String) -> Bool {
        let spec = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(spec as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    private static func matchesIdentifier(guest: SecCode, in allowed: Set<String>) -> Bool {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String else {
            return false
        }
        return allowed.contains(identifier)
    }
}
