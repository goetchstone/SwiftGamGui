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

    /// The screens' words for the sentences a check left out (`LogExplainer.Explanation.dropped`), said against what the
    /// model was given ("the logs", "the report").
    public static func leftOut(_ count: Int, notIn facts: String) -> String {
        count == 1 ? "One of its sentences named a number or an account not in \(facts), so it was left out."
            : "\(count) of its sentences named a number or an account not in \(facts), so they were left out."
    }

    /// Why an answer failed, in words (macOS 27's errors); the error's own description for anything else. Never a failed
    /// answer's raw text. None says "Try again" where trying again can't help: too much to read stays too much, and a
    /// greedy answer fails the same way twice (plan 2026-11-18, A4).
    public static func failure(_ error: any Error) -> String {
        if error is CancellationError { return "it was stopped." }
        if error is SystemLanguageModel.Error { return "the on-device model is still being set up (downloading). Try again in a while." }
        if error is GeneratedContent.ParsingError { return "the model's answer didn't come out whole." }
        guard let error = error as? LanguageModelError else { return error.localizedDescription }
        return switch error {
        case .contextSizeExceeded: "there is more here than the model can read at once. Nothing is lost: the lists are complete without it."
        case .guardrailViolation, .refusal: "the model declined to answer."
        case .rateLimited: "the model is busy. Try again in a moment."
        case .timeout: "the model took too long. Try again."
        case .unsupportedLanguageOrLocale: "the model doesn't support this Mac's language."
        default: error.localizedDescription
        }
    }
}
