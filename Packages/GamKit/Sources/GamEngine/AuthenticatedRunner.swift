import Foundation
import os
import Vault

/// Runs `gam` as a domain: credentials from the Vault into a fresh `EphemeralConfig` for this one
/// call, a refreshed `oauth2.txt` written back, and the directory wiped on every path out.
///
/// Its public `run` takes only a `GamRead`. Writes will reach `gam` through ChangeCore's executor alone
/// (slice 3), which adds the ticket, the write lock, the guard and the audit.
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
        _ read: GamRead,
        as domain: Domain,
        timeout: Duration = GamRunner.defaultTimeout,
        extraEnvironment: [String: String] = [:]
    ) async throws -> GamResult {
        // Only the mock's own variables (passed in debug builds only): a caller outside GamKit can't
        // change HOME, PATH or a proxy for a credentialed call.
        try await run(argv: read.argv, as: domain, timeout: timeout,
                      extraEnvironment: extraEnvironment.filter { GamEnvironment.mockOnly.contains($0.key) })
    }

    /// Any argv, with the domain's credentials. `private`: a write must not reach it except through the
    /// `package` entry point ChangeCore's ticket will gate (slice 3).
    private func run(
        argv: [String],
        as domain: Domain,
        timeout: Duration,
        extraEnvironment: [String: String]
    ) async throws -> GamResult {
        let secrets = try await vault.credentials(for: domain)
        let files = Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.fileName, $0.value.bytes) })
        let config = try EphemeralConfig.materialize(files: files, in: runtimeDirectory)

        let outcome: Result<GamResult, any Error>
        do {
            outcome = .success(try await runner.runRaw(argv, configDirectory: config.url, timeout: timeout,
                                                    extraEnvironment: extraEnvironment))
        } catch {
            outcome = .failure(error)
        }

        // GAM rewrites oauth2.txt when it refreshes the access token; keep the new one, but only in
        // place of the token this call started with: a domain removed mid-call stays removed, and one
        // re-imported mid-call keeps its new token.
        if let refreshed = config.readFile(Credential.oauth2.fileName), !refreshed.isEmpty,
           let original = secrets[.oauth2], refreshed != original.bytes {
            do {
                try await vault.refresh(Secret(refreshed), as: .oauth2, for: domain, replacing: original)
            } catch {
                Self.log.error("could not store the refreshed oauth2.txt: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        if !config.wipe() {
            Self.log.fault("a credential directory survived its wipe: \(config.url.path, privacy: .public)")
        }
        let result = try outcome.get()
        return GamResult(exitCode: result.exitCode,
                         stdout: Self.withoutConfigNoise(result.stdout, configDirectory: config.url),
                         stderr: result.stderr, stdoutTruncated: result.stdoutTruncated,
                         stderrTruncated: result.stderrTruncated)
    }

    /// GamGUI's `strip_cfgdir_noise`: GAM's stdout without the lines naming this call's config
    /// directory. Each call gets a fresh one, so GAM prints its first-run banner on every call
    /// (`Created: <dir>/gamcache`, `Config File: <dir>/gam.cfg, Initialized`), and those lines never
    /// belong to real data. Lines split at each "\n" scalar, a deliberate difference: GamGUI's
    /// `splitlines()` also cut data apart at U+2028. Not at `Character`s: "\r\n" is one `Character`, so a
    /// CRLF banner line and the data after it would have been one line, dropped together.
    static func withoutConfigNoise(_ stdout: String, configDirectory: URL) -> String {
        let needles = Set([configDirectory.path, configDirectory.resolvingSymlinksInPath().path]).filter { !$0.isEmpty }
        guard needles.contains(where: { stdout.contains($0) }) else { return stdout }
        return stdout.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map(PythonText.string)
            .filter { line in !needles.contains { line.contains($0) } }
            .joined(separator: "\n")
    }
}
