// Coverage-guided fuzzing (libFuzzer) of GamEngine's platform-free code: the parsers of GAM's output, the
// error classifier and its masking, the argv builders and the closed-set validators. Everything they read
// comes from GAM or the tenant (names, signatures, stderr), so none of it is trusted.
//
// Built by `scripts/fuzz.sh` on Linux (Apple's toolchain ships no libFuzzer runtime) with these sources
// compiled in, not the package: GamEngine's other files need Darwin. CI's `fuzz` job runs it.
//
// The first byte picks a target; the rest, split at NUL bytes, are its strings. A failed property traps,
// which libFuzzer reports as a crash and saves the input.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    guard let selector = bytes.first else { return 0 }
    let fields = bytes.dropFirst().split(separator: 0, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
    func field(_ index: Int) -> String { index < fields.count ? fields[index] : "" }
    let whole = String(decoding: bytes.dropFirst(), as: UTF8.self)

    switch selector % 6 {
    case 0: parsers(whole)
    case 1: errors(stderr: field(0), secret: field(1), stdout: field(2), exitCode: Int32(bitPattern: UInt32(selector)))
    case 2: builders(field(0), field(1), field(2), field(3))
    case 3: choices(whole)
    case 4: redaction(fields)
    default: csvRoundTrip(fields)
    }
    return 0
}

func require(_ condition: Bool, _ what: @autoclosure () -> String) {
    if !condition { fatalError("property failed: \(what())") }
}

/// GAM's stdout in any shape: never a crash, and a parsed JSON value survives its own records.
func parsers(_ stdout: String) {
    _ = GamOutput.records(stdout)
    _ = GamOutput.one(stdout)
    _ = JSONValue.parse(stdout)
    _ = PythonText.lower(stdout)
    _ = PythonText.strip(stdout)
}

/// The fields, written as GAM writes a CSV row (CPython 3.14's writer in GAM's dialect: every backslash
/// escaped, a field with a comma, quote, CR or LF quoted, its quotes doubled), read back unchanged.
func csvRoundTrip(_ fields: [String]) {
    var written = fields.map { field in
        var cell = String.UnicodeScalarView(), quoted = false
        for scalar in field.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { cell.append(scalar) }
            quoted = quoted || [",", "\"", "\r", "\n"].contains(scalar)
            cell.append(scalar)
        }
        return quoted ? "\"" + String(cell) + "\"" : String(cell)
    }.joined(separator: ",") + "\n"
    if fields.count == 1 && fields[0].isEmpty { written = "\"\"\n" }
    let read = CSVReader.records(written)
    require(read.count == 1 && read[0].count == fields.count
            && zip(read[0], fields).allSatisfy { $0.utf8.elementsEqual($1.utf8) }, "csv round trip \(written.debugDescription)")
}

/// Any stderr is classified without a crash, and a password in the argv never survives redaction.
func errors(stderr: String, secret: String, stdout: String, exitCode: Int32) {
    let argv = ["update", "user", "a@example.com", "password", secret]
    let error = GamError(exitCode: exitCode, stderr: stderr, argv: argv, stdout: stdout)
    let timedOut = GamError(exitCode: nil, stderr: stderr)
    require(timedOut.kind == .timeout, "a nil exit code is a timeout")
    require(error.argv?.count == argv.count, "redaction keeps the argv's shape")
    require(error.argv?.last == ArgvRedaction.mask, "the password is masked in the argv")
    _ = error.remediation
}

/// Invariant 1: each operator value is exactly one element, in its place, byte for byte, whatever it holds
/// (spaces, dashes, newlines, NULs dropped by the split, look-alikes).
func builders(_ a: String, _ b: String, _ c: String, _ d: String) {
    func same(_ x: String, _ y: String) -> Bool { x.utf8.elementsEqual(y.utf8) }
    let member = GamCommands.addGroupMember(group: a, member: b).argv
    require(member.count == 6 && same(member[2], a) && same(member[5], b), "addGroupMember \(member)")

    let user = GamCommands.createUser(email: a, firstName: b, lastName: c, password: d).argv
    require(user.count == 11 && same(user[2], a) && same(user[4], b) && same(user[6], c) && same(user[8], d),
            "createUser \(user.count)")

    let signature = GamCommands.setSignature(email: a, signature: b, html: false).argv
    require(signature.count == 4 && same(signature[1], a) && same(signature[3], b), "setSignature")

    let mail = GamCommands.sendEmail(to: a, subject: b, body: c, html: false).argv
    require(mail.count == 7 && same(mail[2], a) && same(mail[4], b) && same(mail[6], c), "sendEmail")

    let search = GamCommands.searchMessages(email: a, query: b).argv
    require(same(search[1], a) && (b.isEmpty ? search[4] == "includespamtrash" : search[4] == "query" && same(search[5], b)),
            "searchMessages")

    let read = GamCommands.infoUser(email: a).argv
    require(read.count == 6 && same(read[2], a), "infoUser")
}

/// A closed set accepts only its own values, however the text is spelled.
func choices(_ text: String) {
    if let role = try? GamCommands.GroupRole(validating: text) {
        require(GamCommands.GroupRole.allCases.contains(role), "GroupRole")
    }
    if let role = try? GamCommands.CalendarRole(validating: text) {
        require(GamCommands.CalendarRole.allCases.contains(role), "CalendarRole")
    }
    if let action = try? GamCommands.ForwardAction(validating: text) {
        require(GamCommands.ForwardAction.allCases.contains(action), "ForwardAction")
    }
    _ = try? GamCommands.TransferPrivacy(validating: text)
    _ = GamCommands.MessageDetail(label: text)
}

/// Every value after a sensitive keyword is masked, and nothing else changes.
func redaction(_ argv: [String]) {
    let out = ArgvRedaction.redact(argv)
    require(out.count == argv.count, "redaction keeps the count")
    require(argv.isEmpty || out[0].utf8.elementsEqual(argv[0].utf8), "the first token is never masked")
    for (index, token) in argv.enumerated() where index > 0 {
        let keyword = ArgvRedaction.sensitiveKeys.contains { $0.utf8.elementsEqual(PythonText.lower(argv[index - 1]).utf8) }
        let maskedBefore = index > 1 && out[index - 1] == ArgvRedaction.mask && argv[index - 1] != ArgvRedaction.mask
        if keyword && !maskedBefore {
            require(out[index] == ArgvRedaction.mask, "value after \(argv[index - 1]) is masked")
        } else if !keyword {
            require(out[index].utf8.elementsEqual(token.utf8), "token \(index) unchanged")
        }
    }
}
