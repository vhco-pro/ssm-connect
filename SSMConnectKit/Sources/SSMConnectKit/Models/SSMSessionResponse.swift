import Foundation

/// The response from `SSM.StartSession`, passed verbatim (as JSON) to the
/// `session-manager-plugin` to establish the data channel (spec §6.4).
///
/// SDK-free domain type so the tunnel layer and tests don't import `AWSSSM`.
struct SSMSessionResponse: Equatable, Sendable {
    let sessionId: String
    let streamUrl: String
    let tokenValue: String

    /// JSON the plugin expects as its first argument: `{"SessionId","StreamUrl","TokenValue"}`.
    func pluginSessionJSON() throws -> String {
        // Use ordered, explicit keys (the plugin matches on these exact PascalCase names).
        let object: [String: String] = [
            "SessionId": sessionId,
            "StreamUrl": streamUrl,
            "TokenValue": tokenValue,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
