import Testing
@testable import GamEngine

/// Invariant 3 for the typed builders: a `GamRead` is one GamGUI's catalog rule calls confidently
/// read-only, so a write mistyped as a read (which any caller could then run) fails here. The rule is
/// GamGUI's `core/catalog/parser.py`: the first known verb among the first six tokens decides.
@Suite("Command kinds")
struct CommandKindTests {
    // GamGUI's `_READ`, `_DESTRUCTIVE` and `_LOW`, verbatim.
    static let readVerbs: Set = ["print", "show", "info", "list", "get", "report", "whatis", "checkconnection", "version"]
    static let destructiveVerbs: Set = ["delete", "remove", "wipe", "suspend", "deprovision", "purge", "empty", "trash"]
    static let lowVerbs: Set = [
        "add", "update", "create", "set", "modify", "move", "copy", "sync", "transfer", "import",
        "rotate", "clear", "enable", "disable", "reenable", "send", "append", "insert", "replace",
        "unsuspend", "undelete", "accept", "reject", "approve", "hide", "unhide", "archive", "unarchive",
        "upload", "download", "issue", "reset", "generate", "signout", "watch", "claim", "release",
        "select", "use", "cancel", "createcontactgroup",
    ]

    /// Reads GamGUI's verb rule can't place, each reviewed. Nothing else may be added without the same.
    static let reviewedReads: [String: String] = [
        // The catalog has `check serviceaccount` as uncertain: `check` isn't in the verb sets. It only
        // reports whether delegation is authorized; GamGUI's Setup runs it as its read-only verify.
        "check_svcacct": "verifies domain-wide delegation; changes nothing",
    ]

    /// Arguments drawn from a closed set: they keep the fixture's valid value.
    static let closedArguments: Set = ["role", "privacy", "action", "detail"]

    /// The first known verb in `argv`, GamGUI's way, or nil when none is known (uncertain).
    static func verb(_ argv: [String]) -> String? {
        argv.prefix(6).first { readVerbs.contains($0) || destructiveVerbs.contains($0) || lowVerbs.contains($0) }
    }

    /// Each builder called once with placeholder values (`<email>`), so no operator value can be
    /// mistaken for a verb: the verb comes from the builder's own tokens.
    func commands() throws -> [(name: String, command: any GamCommand)] {
        let document = GoldenArgvTests().document
        return try GoldenArgvTests.implemented.keys.sorted().map { name in
            let item = try #require(document.cases.first { $0.builder == name && $0.argv != nil }, "\(name) has no case")
            var kwargs: [String: GoldenArgvTests.Value] = [:]
            for (key, value) in item.kwargs {
                switch value {
                case .string where !Self.closedArguments.contains(key): kwargs[key] = .string("<\(key)>")
                case .strings: kwargs[key] = .strings(["<\(key)>"])
                default: kwargs[key] = value
                }
            }
            return (name, try GoldenArgvTests.implemented[name]!(GoldenArgvTests.Args(kwargs)))
        }
    }

    @Test func everyReadIsConfidentlyReadOnly() throws {
        var reads = 0
        for (name, command) in try commands() where command is GamRead {
            reads += 1
            if Self.reviewedReads[name] != nil {
                #expect(Self.verb(command.argv) == nil, "\(name) now has a known verb: drop its review")
                continue
            }
            let verb = Self.verb(command.argv)
            #expect(verb.map(Self.readVerbs.contains) == true, "\(name) is a GamRead but its verb is \(verb ?? "unknown")")
        }
        #expect(reads == 24)
    }

    @Test func noWriteHasAReadVerb() throws {
        var writes = 0
        for (name, command) in try commands() where command is GamWrite {
            writes += 1
            let verb = Self.verb(command.argv)
            #expect(!(verb.map(Self.readVerbs.contains) ?? false), "\(name) is a GamWrite but reads (\(verb ?? ""))")
        }
        #expect(writes == 34)
    }

    @Test func everyWriteActionIsSomeBuildersAndEachBuilderNamesItsOwn() throws {
        let writes = try commands().compactMap { $0.command as? GamWrite }
        #expect(Set(writes.map(\.action)) == Set(WriteAction.allCases))
        #expect(GamCommands.removeGroupMember(group: "g@example.com", member: "a@example.com").action == .removeGroupMember)
        #expect(GamCommands.addGroupMember(group: "g@example.com", member: "a@example.com").action == .addGroupMember)
    }
}
