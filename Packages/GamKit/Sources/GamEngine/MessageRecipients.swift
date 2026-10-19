/// Who an email was sent to, read from the sender's own copy: `print messages query "rfc822msgid:<id>" … headers all`
/// on the sender's mailbox (`GamCommands.searchMessages`, detail `.headers`). With `headers all`, GAM's `_printMessage`
/// (7.48.30) writes each header under its own name as the message has it ("To", "Cc" or "CC", "Bcc"), a repeat as
/// "To 1", decoded (`_decodeHeader`); `showdate` puts the message's own time in `Date`, and `showlabels` its labels,
/// space-separated. Only the sender's copy can hold a Bcc header, and only when the message was written in Gmail: a
/// mail client or a script sending over SMTP leaves Bcc off what it submits, so the list here may not be everyone
/// (review of 2026-10-19, R1). No copy is GAM's header line alone and exit 60 (NO_ENTITIES_FOUND_RC).
public struct MessageRecipients: Sendable, Equatable {
    /// Each address once (case aside), in the headers' order: To, then Cc, then Bcc.
    public let addresses: [String]
    /// A recipient GAM printed that can't be read as one address: shown as it is, never dropped.
    public let unreadable: [String]
    public let subject: String
    public let from: String
    /// Each distinct From and Subject among the copies, the first first: more than one means the ID matched
    /// different emails.
    public let headings: [Heading]
    /// When Gmail has the message, as GAM prints it.
    public let date: String
    /// Its labels as GAM names them (`SENT`, `TRASH`…).
    public let labels: [String]
    /// The copy has a Bcc header.
    public let hasBcc: Bool

    public struct Heading: Sendable, Equatable {
        public let from: String
        public let subject: String
    }

    /// The sender's copy, or nil when there is none (deleted and purged, or never in that mailbox). Throws the
    /// `GamError` when the read failed, and `Incomplete` when GAM's output passed the runner's cap.
    public static func read(_ result: GamResult, argv: [String]) throws -> MessageRecipients? {
        guard result.exitCode == 0 || result.exitCode == 60 else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else {
            throw MessageCopies.Incomplete(reason: "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so the recipients weren't all read.")
        }
        let records = GamOutput.records(result.stdout)
        // Only GAM's "none found" (60) means no copy: a refused token GAM skips without a word leaves 0 and no row.
        guard !records.isEmpty else {
            if result.exitCode == 60 { return nil }
            throw MessageCopies.Incomplete(reason: "GAM returned nothing for this mailbox, so it may not have been read.")
        }
        var addresses: [String] = [], seen: Set<String> = [], unreadable: [String] = []
        var labels: [String] = [], hasBcc = false
        for kind in ["to", "cc", "bcc"] {
            for record in records {
                // By name, case aside, with GAM's numbered repeats ("To 1"); never "Delivered-To" or "X-Original-To".
                for (column, value) in record.sorted(by: { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) })
                where Self.isHeader(column, kind) {
                    guard let text = value.string else { continue }
                    if kind == "bcc" { hasBcc = true }
                    let read = Self.addresses(in: text)
                    for address in read.addresses where seen.insert(PythonText.lower(address)).inserted { addresses.append(address) }
                    unreadable += read.unreadable
                }
            }
        }
        var headings: [Heading] = []
        for record in records {
            for label in Self.words(record["Labels"]?.string ?? "") where !labels.contains(label) { labels.append(label) }
            let heading = Heading(from: record["From"]?.string ?? "", subject: record["Subject"]?.string ?? "")
            if !headings.contains(heading) { headings.append(heading) }
        }
        return MessageRecipients(addresses: addresses, unreadable: unreadable, subject: records[0]["Subject"]?.string ?? "",
                                 from: records[0]["From"]?.string ?? "", headings: headings, date: records[0]["Date"]?.string ?? "",
                                 labels: labels, hasBcc: hasBcc)
    }

    /// Python's `str.split()`: the words between runs of its whitespace.
    static func words(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: { PythonText.whitespace.contains($0.value) })
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// `column` is header `kind` ("to"), or its numbered repeat ("To 1").
    static func isHeader(_ column: String, _ kind: String) -> Bool {
        let name = PythonText.lower(column)
        if name.unicodeScalars.elementsEqual(kind.unicodeScalars) { return true }
        let prefix = kind + " "
        guard name.unicodeScalars.starts(with: prefix.unicodeScalars) else { return false }
        let rest = name.unicodeScalars.dropFirst(prefix.unicodeScalars.count)
        return !rest.isEmpty && rest.allSatisfy { ("0"..."9").contains($0) }
    }

    /// The addresses in one To, Cc or Bcc header (RFC 5322 `address-list`), as decoded: each `<addr-spec>`, or a bare
    /// one; a display name, quoted or not, a comment and a group's name are never taken for the address. A piece ends
    /// at a comma or a semicolon outside quotes, comments and angle brackets. A piece naming anything but exactly one
    /// address (two angle addresses, two bare ones, an angle address beside a different bare one: the sender wrote the
    /// headers) is returned as it is, unreadable, never cut down to one (review of 2026-10-19, R2). A decoded display
    /// name can hold a comma (`Doe, Jane <jane@example.org>`): its first half has no `@` and names nothing.
    public static func addresses(in header: String) -> (addresses: [String], unreadable: [String]) {
        var addresses: [String] = [], unreadable: [String] = []
        var raw = String.UnicodeScalarView(), plain = String.UnicodeScalarView(), angle = String.UnicodeScalarView()
        var angles: [String] = [], inAngle = false, quoted = false, escaped = false, comment = 0
        func finish() {
            defer {
                raw = .init(); plain = .init(); angle = .init(); angles = []
                inAngle = false; quoted = false; escaped = false; comment = 0
            }
            let piece = PythonText.strip(String(raw))
            guard piece.unicodeScalars.contains("@") else { return }   // a group's end, an empty piece, a name split by a comma
            // Bare words with an @, each past a group's name ("Team:a@example.com"), and every angle address.
            let bare = Self.words(String(plain)).map { word -> String in
                guard let colon = word.unicodeScalars.lastIndex(of: ":") else { return word }
                return String(word.unicodeScalars[word.unicodeScalars.index(after: colon)...])
            }.filter { $0.unicodeScalars.contains("@") }
            let named = angles.map { PythonText.strip($0) } + bare
            let distinct = Set(named.map(PythonText.lower))
            if distinct.count == 1, let address = named.first, Address.looksLikeEmail(address) {
                addresses.append(address)
            } else {
                unreadable.append(piece)
            }
        }
        for scalar in header.unicodeScalars {
            if scalar == "," || scalar == ";", !quoted, comment == 0, !inAngle {
                finish()
                continue
            }
            raw.append(scalar)
            if escaped {
                escaped = false
                if inAngle { angle.append(scalar) }
            } else if quoted {
                if scalar == "\\" { escaped = true } else if scalar == "\"" { quoted = false }
            } else if comment > 0 {
                if scalar == "\\" { escaped = true } else if scalar == "(" { comment += 1 } else if scalar == ")" { comment -= 1 }
            } else if inAngle {
                if scalar == ">" {
                    inAngle = false
                    angles.append(String(angle))
                } else {
                    angle.append(scalar)
                }
            } else {
                switch scalar {
                case "\"": quoted = true
                case "(": comment = 1
                case "<":
                    inAngle = true
                    angle = .init()
                default: plain.append(scalar)
                }
            }
        }
        // An angle address left open at the end is still one the piece names.
        if inAngle { angles.append(String(angle)) }
        finish()
        return (addresses, unreadable)
    }
}

/// The tenant's own mail domains, from `print domains formatjson` (`GamCommands.printDomains`): each verified domain's
/// name and its verified aliases' names, lowercased. An address at any of them is internal; any other, external: mail
/// to a domain not yet verified doesn't reach the tenant (review of 2026-10-19, R4).
public struct TenantDomains: Sendable, Equatable {
    public let names: Set<String>

    public init(names: Set<String>) {
        self.names = Set(names.map(PythonText.lower))
    }

    /// Throws the `GamError` for a failed read, and `Incomplete` for one that names no verified domain.
    public static func read(_ result: GamResult, argv: [String]) throws -> TenantDomains {
        guard result.exitCode == 0 else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        var names: Set<String> = []
        for record in GamOutput.records(result.stdout) where record["verified"]?.bool == true {
            if let name = record["domainName"]?.string { names.insert(name) }
            for alias in record["domainAliases"]?.array ?? [] where alias.object?["verified"]?.bool == true {
                if let name = alias.object?["domainAliasName"]?.string { names.insert(name) }
            }
        }
        guard !names.isEmpty else {
            throw MessageCopies.Incomplete(reason: "GAM listed no verified domain for this tenant, so inside can't be told from outside.")
        }
        return TenantDomains(names: names)
    }

    /// The address's domain, after its last `@`, is one of the tenant's.
    public func isInternal(_ address: String) -> Bool {
        guard let at = address.unicodeScalars.lastIndex(of: "@") else { return false }
        let domain = PythonText.lower(PythonText.strip(String(address.unicodeScalars[address.unicodeScalars.index(after: at)...])))
        return names.contains(domain)
    }
}
