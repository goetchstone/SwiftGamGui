import Foundation
import FoundationModels

/// What both explanations (the log reader's, the connected apps') say about Apple's on-device model, in words: whether it
/// can answer now, and why an answer failed.
public enum OnDeviceModel {
    /// Why the model can't answer now, or nil when it can; `purpose` finishes "turn it on in System Settings to have …"
    /// ("the logs explained").
    public static func unavailable(_ purpose: String) -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple's on-device model."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off: turn it on in System Settings to have \(purpose)."
        case .unavailable(.modelNotReady): "The on-device model is still being set up (downloading). Try again in a while."
        case .unavailable: "The on-device model isn't available."
        }
    }

    /// Why an answer failed, in words (macOS 27's `LanguageModelError`); the error's own description for anything else.
    public static func failure(_ error: any Error) -> String {
        guard let error = error as? LanguageModelError else { return error.localizedDescription }
        return switch error {
        case .contextSizeExceeded: "its answer ran longer than the model allows. Try again."
        case .guardrailViolation, .refusal: "the model declined to answer."
        case .rateLimited: "the model is busy. Try again in a moment."
        case .timeout: "the model took too long. Try again."
        case .unsupportedLanguageOrLocale: "the model doesn't support this Mac's language."
        default: error.localizedDescription
        }
    }
}
