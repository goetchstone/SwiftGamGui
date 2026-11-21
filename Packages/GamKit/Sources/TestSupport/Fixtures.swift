import Foundation

/// The repo's shared fixtures (`Tests/Fixtures`), found from this source file's location, so the package
/// tests and the app's tests read the same files.
public enum Fixtures {
    /// `<repo>/Packages/GamKit/Sources/TestSupport/Fixtures.swift` → `<repo>`.
    public static let repoRoot: URL = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    public static var directory: URL { repoRoot.appending(path: "Tests/Fixtures") }
    public static var mockGam: URL { directory.appending(path: "mock_gam.sh") }
    public static var mockGamData: URL { directory.appending(path: "mock_gam") }
    public static var argvJSON: URL { directory.appending(path: "argv.json") }
    public static var exitCodesJSON: URL { directory.appending(path: "exit_codes.json") }
    public static var gamErrorsJSON: URL { directory.appending(path: "gam_errors.json") }
    public static var gamOutputJSON: URL { directory.appending(path: "gam_output.json") }
    public static var setupJSON: URL { directory.appending(path: "setup.json") }
    public static var vacationJSON: URL { directory.appending(path: "vacation.json") }
    public static var signaturesJSON: URL { directory.appending(path: "signatures.json") }
    public static var offboardingJSON: URL { directory.appending(path: "offboarding.json") }
    public static var onboardingJSON: URL { directory.appending(path: "onboarding.json") }
    public static var gamModelsJSON: URL { directory.appending(path: "gam_models.json") }
    public static var guardJSON: URL { directory.appending(path: "guard.json") }
    public static var auditJSON: URL { directory.appending(path: "audit.json") }
    public static var reportsJSON: URL { directory.appending(path: "reports.json") }
    public static var catalogJSON: URL { repoRoot.appending(path: "Vendor/gam7/command_catalog.json") }
    public static var fetchScript: URL { repoRoot.appending(path: "scripts/fetch_gam.sh") }

    /// The mock's own environment: where its canned output lives.
    public static var mockEnvironment: [String: String] {
        ["GAM_MOCK_FIXTURES": mockGamData.path]
    }

    /// The Google account ID the mock's directory gives `email` (`mock_gam/print_users.json`'s `id`); nil for no such user.
    public static func mockAccountID(_ email: String) -> String? {
        guard let text = try? String(contentsOf: mockGamData.appending(path: "print_users.json"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (record["primaryEmail"] as? String) == email.lowercased() else { continue }
            return record["id"] as? String
        }
        return nil
    }

    /// An `oauth2.txt` that signs in as `admin`, as GAM writes one: the claims beside the token, with the account ID (`sub`)
    /// the mock's directory has for that admin, so Setup's Check access confirms it. A placeholder, never a real token.
    /// `scopes`, when given, is recorded as GAM records the admin token's (`oauth2.txt`'s top-level `scopes`).
    public static func oauth2(admin: String, scopes: [String]? = nil) -> Data {
        let sub = mockAccountID(admin).map { #", "sub": "\#($0)""# } ?? ""
        let granted = scopes.map { #", "scopes": [\#($0.map { "\"\($0)\"" }.joined(separator: ", "))]"# } ?? ""
        return Data(#"{"decoded_id_token": {"email": "\#(admin)"\#(sub)}, "refresh_token": "placeholder"\#(granted)}"#.utf8)
    }

    /// A stand-in `gam` in `folder` for the strict mock plus `user <email> print signature`, the exact read ChangeCore keeps
    /// before a signature is replaced, until the mock models it from GAM's source (with the fixtures' next regeneration).
    /// Every other call is the mock's own. The read first asks the mock's `show signature` about the person, so an unknown
    /// user or Gmail off fails in the mock's words; then it prints, as GAM 7.52.04's printShowSignature does, the getting
    /// line on stderr and its titles and the person's row, the signature the mock last set (`GAM_MOCK_STATE`) or the mock's
    /// canned one, quoted as GAM's CSV writer quotes, and no `signature` column for none.
    public static func gamReadingSignatures(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "gam-reading-signatures.sh")
        let script = #"""
        #!/bin/sh
        mock='\#(mockGam.path)'
        if [ "${1:-}" = user ] && [ "${3:-}" = print ] && [ "${4:-}" = signature ] && [ $# -eq 4 ]; then
          [ -z "${GAM_MOCK_ARGV_LOG:-}" ] || printf '%s\0' "$#" "$@" >> "$GAM_MOCK_ARGV_LOG"
          user=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
          err=$(GAM_MOCK_ARGV_LOG= "$mock" user "$user" show signature 2>&1 >/dev/null); rc=$?
          if [ "$rc" -ne 0 ]; then printf '%s\n' "$err" >&2; exit "$rc"; fi
          printf 'Getting Signatures for %s\n' "$user" >&2
          sfile="${GAM_MOCK_STATE:-}/signature/$user"
          if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$sfile" ]; then
            sig=$(cat "$sfile"; printf .); sig=${sig%.}
          else
            case "$user" in
              alice@example.com) sig='Best,<br>Alice' ;;
              carol@example.com) sig='Carol Clark<br>Operations' ;;
              *) sig='' ;;
            esac
          fi
          titles='User,displayName,sendAsEmail,replyToAddress,isPrimary,isDefault,treatAsAlias,verificationStatus'
          row="$user,,$user,,True,True,,"
          if [ -z "$sig" ]; then printf '%s\n%s\n' "$titles" "$row"; exit 0; fi
          cell=$(printf '%s.' "$sig" | LC_ALL=C sed 's/\\/\\\\/g'); cell=${cell%.}
          nl='
        '
          case "$cell" in
            *[,\"]*|*"$nl"*|*"$(printf '\r')"*)
              cell=$(printf '%s.' "$cell" | LC_ALL=C sed 's/"/""/g'); cell="\"${cell%.}\"" ;;
          esac
          printf '%s,signature\n%s,%s\n' "$titles" "$row" "$cell"
          exit 0
        fi
        exec "$mock" "$@"
        """#
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// A fresh temp dir holding placeholder credential files. The mock only checks that they exist and
    /// aren't empty; nothing real is ever written here.
    public static func placeholderConfigDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for name in ["oauth2service.json", "oauth2.txt"] {
            try Data("{\"placeholder\": true}".utf8).write(to: dir.appending(path: name))
        }
        return dir
    }
}
