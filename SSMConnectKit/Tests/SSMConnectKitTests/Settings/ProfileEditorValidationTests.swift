import Testing
@testable import SSMConnectKit

// Verifies: Fix opaque region-failure on Connect, Criterion: "An empty or malformed region entered in the Profile Editor disables Save (and shows a field-level error when non-empty-but-malformed); a valid region re-enables Save and clears the error."
@Suite("ProfileEditorValidation")
struct ProfileEditorValidationTests {

    @Test("an empty region disables Save but shows no error (fresh form is quiet)")
    func emptyRegion() {
        let state = ProfileEditorValidation.regionState("")
        #expect(state.isValid == false)   // Save disabled
        #expect(state.showError == false)  // no noisy error on an empty field

        // Whitespace-only behaves like empty after trimming.
        let blank = ProfileEditorValidation.regionState("   ")
        #expect(blank.isValid == false)
        #expect(blank.showError == false)
    }

    @Test("a non-empty malformed region disables Save and shows the field error")
    func malformedRegion() {
        for bad in ["eu_central_1", "-eu", "eu-", "eu central 1"] {
            let state = ProfileEditorValidation.regionState(bad)
            #expect(state.isValid == false, "\(bad) should be invalid")
            #expect(state.showError == true, "\(bad) should show the field error")
        }
    }

    @Test("a valid region enables Save and clears the error, tolerating surrounding whitespace")
    func validRegion() {
        for good in ["eu-central-1", "us-east-1", "  eu-west-1  "] {
            let state = ProfileEditorValidation.regionState(good)
            #expect(state.isValid == true, "\(good) should be valid after trim")
            #expect(state.showError == false, "\(good) should not show an error")
        }
    }
}
