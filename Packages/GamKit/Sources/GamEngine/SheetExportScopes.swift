import Foundation

// Apart from SheetExport.swift because `AccessCheck` needs Vault (Darwin): the rest of SheetExport is platform-free, so the
// Linux fuzz build (scripts/fuzz.sh) compiles it beside GamCommand.swift, which reads an export's output through it.
extension SheetExport {
    /// The scope check's answer, from `check serviceaccount scopes <drive>,<spreadsheets>` (GamGUI's `sheet_export_scopes`):
    /// each scope and whether the service account may use it for the admin, or nil when it couldn't be told (another exit than
    /// 0 or a failed scope's 10, or a row missing), which is never "allowed" (invariant 10).
    public static func checked(_ result: GamResult) -> [String: Bool]? {
        guard result.exitCode == 0 || result.exitCode == GamExitCode.scopesNotAuthorized else { return nil }
        var rows: [String: Bool] = [:]
        for row in AccessCheck.rows(in: result.stdout) { rows[PythonText.lower(row.label)] = row.passed }
        var checked: [String: Bool] = [:]
        for (scope, _) in scopes {
            guard let allowed = rows[scope] else { return nil }
            checked[scope] = allowed
        }
        return checked
    }
}
