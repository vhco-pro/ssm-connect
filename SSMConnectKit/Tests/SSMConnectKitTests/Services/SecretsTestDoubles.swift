import AWSSecretsManager
import Foundation
@testable import SSMConnectKit

/// Configurable `SecretsClienting` double for `SecretsService` unit tests.
final class MockSecretsClient: SecretsClienting, @unchecked Sendable {
    var result: Result<GetSecretValueOutput, Error> = .success(GetSecretValueOutput(secretString: "hunter2"))
    private(set) var inputs: [GetSecretValueInput] = []

    func getSecretValue(_ input: GetSecretValueInput) async throws -> GetSecretValueOutput {
        inputs.append(input)
        return try result.get()
    }
}
