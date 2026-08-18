import Testing
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow
@testable import SSMConnectAWS
@testable import SSMConnectMacOS
@testable import SSMConnectUI

// Verifies: Fix opaque region-failure on Connect, Criterion: "For region inputs `eu-central-1`, `us-east-1` (valid) and ``, ` `, `eu-central-1 `, `-eu`, `eu-`, `eu_central_1`, a 64-char string (invalid), `AWSRegion.isValid`/`normalize` verdicts match the SDK regex `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$` semantics."
@Suite("AWSRegion")
struct AWSRegionTests {

    @Test("isValid matches the SDK regex semantics", arguments: [
        // (input, expected)
        ("eu-central-1", true),
        ("us-east-1", true),
        ("EU-CENTRAL-1", true),          // regex is case-insensitive on the character class
        (String(repeating: "a", count: 63), true),   // boundary: 63 chars is the max allowed
        ("", false),                     // empty
        (" ", false),                    // whitespace only
        ("eu-central-1 ", false),        // trailing space
        (" eu-central-1", false),        // leading space
        ("-eu", false),                  // leading hyphen
        ("eu-", false),                  // trailing hyphen
        ("eu_central_1", false),         // underscore not allowed
        ("eu central 1", false),         // interior space
        (String(repeating: "a", count: 64), false),   // boundary: 64 chars exceeds max
    ])
    func isValidVerdicts(input: String, expected: Bool) {
        #expect(AWSRegion.isValid(input) == expected)
    }

    @Test("normalize trims surrounding whitespace and newlines without altering the interior")
    func normalizeTrims() {
        #expect(AWSRegion.normalize("  eu-central-1  ") == "eu-central-1")
        #expect(AWSRegion.normalize("\teu-west-1\n") == "eu-west-1")
        #expect(AWSRegion.normalize("eu-central-1") == "eu-central-1")
        #expect(AWSRegion.normalize("") == "")
    }

    @Test("a value that is invalid raw becomes valid once normalized")
    func normalizeThenValid() {
        let raw = " eu-central-1 "
        #expect(AWSRegion.isValid(raw) == false)
        #expect(AWSRegion.isValid(AWSRegion.normalize(raw)) == true)
    }
}
