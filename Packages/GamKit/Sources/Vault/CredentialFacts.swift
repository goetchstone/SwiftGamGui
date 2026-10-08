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

    /// The service account's client ID (`oauth2service.json`), for the delegation link.
    public static func clientID(inServiceAccount data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["client_id"] as? String
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
