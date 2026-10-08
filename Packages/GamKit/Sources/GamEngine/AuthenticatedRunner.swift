import Foundation
import os
import Vault

/// Runs `gam` as a domain: credentials from the Vault into a fresh `EphemeralConfig` for this one
/// call, a refreshed `oauth2.txt` written back, and the directory wiped on every path out.
///
/// Reads and writes alike come through here; ChangeCore (phase 2) adds the write lock, the guard and
/// the audit around it.
public struct AuthenticatedRunner: Sendable {
    public let runner: GamRunner
    public let vault: Vault
    public let runtimeDirectory: URL

    private static let log = Logger(subsystem: "io.github.goetchstone.swiftgamgui", category: "credentials")

    public init(runner: GamRunner, vault: Vault, runtimeDirectory: URL) {
        self.runner = runner
        self.vault = vault
        self.runtimeDirectory = runtimeDirectory
    }

    public func run(
        _ argv: [String],
        as domain: Domain,
        timeout: Duration = GamRunner.defaultTimeout,
        extraEnvironment: [String: String] = [:]
    ) async throws -> GamResult {
        let secrets = try await vault.credentials(for: domain)
        let files = Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.fileName, $0.value.bytes) })
        let config = try EphemeralConfig.materialize(files: files, in: runtimeDirectory)

        let outcome: Result<GamResult, any Error>
        do {
            outcome = .success(try await runner.run(argv, configDirectory: config.url, timeout: timeout,
                                                    extraEnvironment: extraEnvironment))
        } catch {
            outcome = .failure(error)
        }

        // GAM rewrites oauth2.txt when it refreshes the access token; keep the new one.
        if let refreshed = config.readFile(Credential.oauth2.fileName), !refreshed.isEmpty,
           refreshed != secrets[.oauth2]?.bytes {
            do {
                try await vault.store(Secret(refreshed), as: .oauth2, for: domain)
            } catch {
                Self.log.error("could not store the refreshed oauth2.txt: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        if !config.wipe() {
            Self.log.fault("a credential directory survived its wipe: \(config.url.path, privacy: .public)")
        }
        return try outcome.get()
    }
}
