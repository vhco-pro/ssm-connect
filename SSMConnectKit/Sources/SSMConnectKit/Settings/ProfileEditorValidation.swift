import Foundation

/// Pure, SwiftUI-free validation decisions for the profile editor's region fields, so the
/// Save-gate and inline-error behaviour can be unit-tested without rendering a view.
enum ProfileEditorValidation {
    /// The display decision for a single region field.
    struct RegionFieldState: Equatable {
        /// Whether the field's (trimmed) value is an acceptable AWS region. Drives the Save gate.
        var isValid: Bool
        /// Whether to show an inline field-level error. True only when the field is non-empty but
        /// invalid, so a fresh, empty form is not noisy.
        var showError: Bool
    }

    /// Evaluate a raw region field value (as typed, possibly with surrounding whitespace).
    static func regionState(_ raw: String) -> RegionFieldState {
        let trimmed = AWSRegion.normalize(raw)
        let valid = AWSRegion.isValid(trimmed)
        return RegionFieldState(isValid: valid, showError: !trimmed.isEmpty && !valid)
    }
}
