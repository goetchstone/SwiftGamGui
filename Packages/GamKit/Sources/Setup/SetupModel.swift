import Foundation
import GamEngine
import Observation
import Vault

/// The Setup screen's state and actions: which domains have credentials, which one GamGUI is connected
/// to, importing (from a GAM folder or from the Python GamGUI's Keychain), Check access, and removal.
/// The view only renders this and calls it; everything here is testable without a window.
@MainActor
@Observable
public final class SetupModel {
    public enum Activity: Equatable, Sendable {
        case idle
        case working(String)
        case done(String)
        case problem(String)
    }

    public struct CheckRecord: Equatable, Sendable {
        public let domain: Domain
        public let admin: String
        public let result: AccessCheck
    }

    public private(set) var domains: [Domain] = []
    /// The domain whose last Check access passed: the one every other screen acts on.
    public private(set) var active: Domain?
    /// Bumps whenever the active domain changes. Anything made for an older generation (a preview, a
    /// cache, a read in flight) belongs to another tenant and must be dropped (GamGUI failure-log
    /// 2026-09-25: a tenant switch left the old tenant's previews live). A re-check of the same domain
    /// keeps it.
    public private(set) var generation = 0
    public private(set) var activity: Activity = .idle
    public private(set) var lastCheck: CheckRecord?
    /// GamGUI's domains, once looked up (reading them asks the operator to Allow access).
    public private(set) var gamguiEntries: [GamGUIKeychain.Entry]?

    private let vault: Vault
    private let runner: AuthenticatedRunner?
    private let gamgui: GamGUIKeychain
    private let readFolder: @Sendable (URL) throws -> [Credential: Secret]

    public init(
        vault: Vault,
        runner: AuthenticatedRunner?,
        gamgui: GamGUIKeychain = GamGUIKeychain(),
        readFolder: @escaping @Sendable (URL) throws -> [Credential: Secret] = CredentialFolder.read
    ) {
        self.vault = vault
        self.runner = runner
        self.gamgui = gamgui
        self.readFolder = readFolder
    }

    public func refresh() async {
        do {
            domains = try await vault.domains()
        } catch {
            activity = .problem(Self.message(for: error))
        }
    }

    /// The domain part of the admin address in the folder's `oauth2.txt`, to pre-fill the domain field.
    public func suggestedDomain(for folder: URL) async -> String? {
        let read = readFolder
        guard let found = try? await Self.offMain({ try read(folder) }),
              let token = found[.oauth2],
              let email = CredentialFacts.adminEmail(inOAuth2: token.bytes)
        else { return nil }
        return email.split(separator: "@").last.map(String.init)
    }

    public func importFolder(_ folder: URL, as domainText: String) async {
        guard let domain = Domain(domainText) else {
            activity = .problem("“\(domainText)” isn't a domain name.")
            return
        }
        activity = .working("Importing credentials for \(domain)…")
        do {
            let read = readFolder
            try await store(try await Self.offMain({ try read(folder) }), for: domain)
            await refresh()
            activity = .done("Imported \(domain). Check access next.")
        } catch {
            activity = .problem(Self.message(for: error))
        }
    }

    public func lookForGamGUI() async {
        activity = .working("Reading GamGUI's list of domains. macOS may ask you to allow access.")
        do {
            let gamgui = gamgui
            let entries = try await Self.offMain({ try gamgui.entries() })
            gamguiEntries = entries
            activity = entries.isEmpty ? .done("GamGUI has no stored domains.") : .idle
        } catch {
            activity = .problem(Self.message(for: error))
        }
    }

    public func copy(_ entry: GamGUIKeychain.Entry) async {
        activity = .working("Copying \(entry.spelling) from GamGUI. macOS asks you to allow each item.")
        do {
            let gamgui = gamgui
            let found = try await Self.offMain({ try gamgui.credentials(for: entry) })
            let missing = Credential.required.filter { found[$0] == nil }
            guard missing.isEmpty else {
                activity = .problem("GamGUI has no \(missing.map(\.fileName).joined(separator: " or ")) for \(entry.spelling).")
                return
            }
            try await store(found, for: entry.domain)
            await refresh()
            activity = .done("Copied \(entry.domain) from GamGUI. Check access next.")
        } catch {
            activity = .problem(Self.message(for: error))
        }
    }

    /// Runs Check access as the admin in the domain's `oauth2.txt` (or `typedAdmin` when it names
    /// none). Only a pass makes the domain active; a failed check leaves the active one as it was.
    public func checkAccess(_ domain: Domain, typedAdmin: String = "") async {
        guard let runner else {
            activity = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        activity = .working("Checking access to \(domain)…")
        do {
            let token = try await vault.credentials(for: domain)[.oauth2]
            let typed = typedAdmin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let admin = token.flatMap({ CredentialFacts.adminEmail(inOAuth2: $0.bytes) })
                ?? (typed.contains("@") ? typed : nil)
            else {
                activity = .problem("This domain's oauth2.txt names no admin. Enter the admin address GAM signs in as.")
                return
            }
            let result = try await runner.checkAccess(admin: admin, as: domain)
            lastCheck = CheckRecord(domain: domain, admin: admin, result: result)
            if result.isAuthorized {
                activate(domain)
                activity = .done("Connected to \(domain) as \(admin).")
            } else {
                activity = .problem(Self.summary(of: result))
            }
        } catch {
            activity = .problem(Self.message(for: error))
        }
    }

    public func remove(_ domain: Domain) async {
        activity = .working("Removing \(domain)…")
        do {
            try await vault.remove(domain)
            if active == domain {
                active = nil
                generation += 1
            }
            if lastCheck?.domain == domain { lastCheck = nil }
            await refresh()
            activity = .done("Removed \(domain)'s credentials from this Mac.")
        } catch {
            await refresh()
            activity = .problem(Self.message(for: error))
        }
    }

    private func activate(_ domain: Domain) {
        guard active != domain else { return }
        active = domain
        generation += 1
    }

    private func store(_ found: [Credential: Secret], for domain: Domain) async throws {
        for credential in Credential.removalOrder.reversed() {
            if let secret = found[credential] {
                try await vault.store(secret, as: credential, for: domain)
            }
        }
    }

    /// File and Keychain reads can block (a prompt, a slow volume): never on the main actor.
    private static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    // MARK: - Words for the operator

    public static func summary(of check: AccessCheck) -> String {
        switch check.outcome {
        case .authorized:
            return "All scopes authorized."
        case .delegationIncomplete(let failed, let total) where failed > 0:
            return "Domain-wide delegation isn't authorized for \(failed) of \(total) scopes yet. Use the link, then check again."
        case .delegationIncomplete:
            return "Domain-wide delegation isn't authorized yet. Use the link, then check again."
        case .serviceAccountProblem(let checks):
            return "GAM's service-account check failed: \(checks.joined(separator: "; ")). A rejected key means it was deleted or rotated: import a current one. A failed clock check means this Mac's time is off."
        case .failed(let line):
            return "GAM failed: \(line)"
        }
    }

    public static func message(for error: any Error) -> String {
        switch error {
        case let error as VaultError:
            return error.guidance
        case let failure as CredentialFolder.Failure:
            switch failure {
            case .notAFolder: return "That isn't a folder GamGUI can read."
            case .missing(let credentials):
                return "The folder has no \(credentials.map(\.fileName).joined(separator: " or ")). Choose your GAM config folder (often ~/.gam)."
            case .notARegularFile(let name): return "\(name) isn't a regular file (a link or something else). Copy the real file into the folder."
            case .tooLarge(let name): return "\(name) is far larger than a GAM credential file."
            case .notJSON(let name): return "\(name) isn't a UTF-8 JSON file."
            case .notAServiceAccount: return "oauth2service.json doesn't name a service account."
            case .unreadable(let name, let code): return "\(name) couldn't be read (\(String(cString: strerror(code))))."
            }
        case let failure as GamRunnerError:
            switch failure {
            case .timedOut(let seconds): return "GAM didn't answer within \(seconds) seconds."
            case .binaryNotExecutable, .launchFailed: return "GAM couldn't start (\(failure))."
            case .invalidArgument: return "That value can't be passed to GAM."
            }
        case let failure as EphemeralConfig.Failure:
            return "The private folder for GAM's credentials couldn't be set up (\(failure))."
        default:
            return "\(error)"
        }
    }
}
