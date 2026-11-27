import Foundation

/// The org unit tree (GamGUI's `org_units`, roadmap 4.2): every path, the root `/` first then the rest in code-point order.
public enum OrgUnits {
    /// GamGUI's reading of `print orgs fields orgunitpath,name,description`: the titles line is the answer. A notice GAM printed
    /// before it is skipped, and output without it never answered (nil: unread, never "only /"). Lines split on "\n" only, so a
    /// line separator inside a description stays in its cell.
    public static func paths(_ stdout: String) -> [String]? {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { line in
            line.split(separator: ",", omittingEmptySubsequences: false).contains { PythonText.strip(String($0)) == "orgUnitPath" }
        }) else { return nil }
        let records = GamOutput.records(lines[start...].joined(separator: "\n"))
        let paths = Set(records.map { PythonText.strip($0["orgUnitPath"]?.string ?? "") }.filter { $0.hasPrefix("/") && $0 != "/" })
        return ["/"] + paths.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }
}
