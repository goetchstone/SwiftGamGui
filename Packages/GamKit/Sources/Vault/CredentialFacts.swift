import Foundation
import Security

/// The few non-secret facts Setup shows, read from credential bytes in memory. Only these values ever
/// leave this file: never a token or a key.
public enum CredentialFacts {
    /// The connected admin's address: the `email` claim GAM keeps beside the token in `oauth2.txt`
    /// (`decoded_id_token`, or `id_token` when an older build stored the claims there), lowercased.
    /// An undecoded JWT is not decoded. Port of GamGUI's `oauth_admin_email`.
    public static func adminEmail(inOAuth2 data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["decoded_id_token", "id_token"] {
            var claims = object[key]
            if let text = claims as? String {
                claims = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
            if let email = (claims as? [String: Any])?["email"] as? String, email.contains("@"),
               !email.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) {
                return email.lowercased()
            }
        }
        return nil
    }

    /// The scopes the admin token was granted (`oauth2.txt`'s top-level `scopes`), when recorded.
    public static func grantedScopes(inOAuth2 data: Data) -> [String]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["scopes"] as? [String]
    }

    /// The service account's client ID (`oauth2service.json`), for the delegation step, as GamGUI's
    /// `str(_json_field(raw, "client_id") or "")` reads it: a string as is, an integer in digits, and
    /// empty when absent, empty or zero. Held to `Tests/Fixtures/setup.json`. Deliberate differences, none
    /// in a file Google issues (its client ID is a string): a boolean, float, list or object (Python would
    /// print its repr) or an integer past 64 bits is empty, so it makes no link; and with a duplicate key
    /// `JSONSerialization` keeps the first value where Python keeps the last.
    public static func clientID(inServiceAccount data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        switch object["client_id"] {
        case let text as String:
            return text
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID() && !CFNumberIsFloatType(number):
            return number.stringValue == "0" ? "" : number.stringValue
        default:
            return ""
        }
    }

    /// The admin-token scope offboarding's sign-out needs ("Directory API - User Security", ticked when
    /// GAM's OAuth client is created): a client-access scope, so delegation can't grant it.
    public static let userSecurityScope = "https://www.googleapis.com/auth/admin.directory.user.security"

    /// Whether the admin token was granted `userSecurityScope`; nil when its scopes aren't recorded as a
    /// list. GamGUI's `dwd_details` `user_security`, held to `Tests/Fixtures/setup.json`.
    public static func grantsUserSecurity(inOAuth2 data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let granted = object["scopes"] as? [Any]
        else { return nil }
        return granted.contains { ($0 as? String)?.utf8.elementsEqual(userSecurityScope.utf8) == true }
    }
}

extension VaultError {
    /// What the operator should read: an action, not a status code.
    public var guidance: String {
        switch self {
        case .missing(let domain, let credentials):
            "No \(credentials.map(\.fileName).joined(separator: " or ")) stored for \(domain). Import the credentials first."
        case .accessControlUnavailable:
            "macOS couldn't create the Touch ID protection for this item. Try again."
        case .keychain(let status):
            switch status {
            case errSecInteractionNotAllowed: "Your Mac is locked. Unlock it and try again."
            case errSecUserCanceled: "Cancelled."
            case errSecAuthFailed: "Authentication failed. Try again with Touch ID or your login password."
            case errSecMissingEntitlement:
                "This build can't use the Keychain: it isn't signed with a team. See the README's build steps."
            default:
                "The Keychain refused (\(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown"))."
            }
        }
    }
}
