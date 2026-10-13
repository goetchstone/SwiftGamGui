/// Onboarding's pure core: GamGUI's `core/onboarding.py`, ported to the letter where its words or
/// decisions reach the operator or GAM.

extension GamError {
    /// GamGUI's `not_ready_yet`: how GAM reports an account Google hasn't finished setting up. Live,
    /// 2026-09-30, a signature set 1 s after the create failed "Requested client not authorized" and a
    /// calendar subscribe 7 s after it "Calendar Service/App not enabled"; both worked minutes later. Ask
    /// it only about an account the same run just created: on an existing user the same words mean a
    /// missing delegation scope or a service turned off. Over `message`, as GamGUI reads `str(exc)`, its
    /// pattern case-insensitive as `re.I` reads it.
    public var saysNewAccountNotReady: Bool {
        kind == .serviceNotEnabled || Folded(message).has("requested client not authorized")
    }
}
