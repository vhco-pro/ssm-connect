import Foundation
import SSMConnectDomain

/// The Session Manager plugin's command line, the same on every platform: the session JSON,
/// the region, "StartSession", an empty profile and the session parameters.
package enum PluginArguments {
    package static let portForwardDocument = "AWS-StartPortForwardingSession"

    package static func portForward(session: SSMSessionResponse, region: String, instanceId: String,
                                    localPort: Int, remotePort: Int) throws -> [String] {
        let parameters: [String: Any] = [
            "Target": instanceId,
            "DocumentName": portForwardDocument,
            "Parameters": ["portNumber": [String(remotePort)], "localPortNumber": [String(localPort)]],
        ]
        let parameterJSON = String(decoding: try JSONSerialization.data(withJSONObject: parameters), as: UTF8.self)
        return [try session.pluginSessionJSON(), region, "StartSession", "", parameterJSON]
    }
}
