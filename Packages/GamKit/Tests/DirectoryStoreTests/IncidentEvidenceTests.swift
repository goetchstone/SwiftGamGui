import Foundation
@testable import Directory
import GamEngine
import Testing

/// An incident's evidence as one pull (`IncidentLogs.evidence`): what each export's `about.txt` says, and how several
/// exports of the same logs are put together.
@Suite("Incident evidence")
struct IncidentEvidenceTests {
    static let header = "log,time,actor,event,ip_address,flagged,via,parameters\r\n"

    static func export(_ name: String, about: String, login: [String]) -> ActivityLogs.Export {
        ActivityLogs.Export(name: name, about: about, logs: [(.login, header + login.map { $0 + "\r\n" }.joined())])
    }

    static let early = "login,2026-10-19T13:00:00Z,carol@example.com,login_success,198.51.100.23,yes,,"
    static let late = "login,2026-10-22T09:00:00Z,carol@example.com,login_success,192.0.2.10,,,"

    /// The window, the accounts, the address, and each log's own window and cap, as Export All writes them.
    @Test func aboutIsReadBack() {
        let about = IncidentLogs.About("""
            Incident logs exported 2026-10-23 0619 America/New_York.
            Over the last 30 days.
            Accounts: carol@example.com, dana@example.com.
            From IP address: 198.51.100.23.

            login-log.csv: the Sign-ins (user log) log, 12 events.
            gmail-log.csv: the Gmail log, 9890 events, the last 30 days (the most it reads); older events past the cap weren't read.
            """)
        #expect(about.hours == 720 && about.users == ["carol@example.com", "dana@example.com"] && about.ip == "198.51.100.23")
        #expect(about.capped == [.gmail] && about.window == [.gmail: 720])
        let every = IncidentLogs.About("Over the last 12 hours.\nAccounts: every account.\nFrom IP address: any.\n")
        #expect(every.hours == 12 && every.users.isEmpty && every.ip.isEmpty)
        // A read stopped at its bound, oldest first: read completely through a time, the later events not; a window as times.
        let rest = IncidentLogs.About("From 2026-10-13T00:00:00Z to 2026-10-23T00:00:00Z.\n"
            + "gmail-log.csv: the Gmail log, 200000 events; read completely through 2026-10-16T00:00:00Z, later events weren't read.\n")
        #expect(rest.hours == 240 && rest.capped == [.gmail])
        #expect(rest.through[.gmail] == (try? Date("2026-10-16T00:00:00Z", strategy: .iso8601)))
    }

    /// The address a saved read of every account was made from (slice 7: that address's sweep is done); never one for some
    /// accounts, by no address, or with its Accounts line missing.
    @Test func whichAddressAReadOfEveryAccountWasFrom() {
        func about(_ accounts: String?, _ address: String) -> String {
            "Incident logs exported 2026-10-27 0900 UTC.\nOver the last 30 days.\n" + (accounts.map { "Accounts: \($0).\n" } ?? "")
                + "From IP address: \(address).\n\ngmail-log.csv: the Gmail log, 12 events.\n"
        }
        #expect(IncidentLogs.sweptAddress(about: about("every account", "198.51.100.23")) == "198.51.100.23")
        #expect(IncidentLogs.sweptAddress(about: about("every account", "2001:db8::7")) == "2001:db8::7")
        #expect(IncidentLogs.sweptAddress(about: about("carol@example.com", "198.51.100.23")) == nil)
        #expect(IncidentLogs.sweptAddress(about: about("every account", "any")) == nil)
        #expect(IncidentLogs.sweptAddress(about: about(nil, "198.51.100.23")) == nil)
    }

    /// How far a read of every account will get, from its first full read (slice 7): the events an hour over that read's
    /// span, then how much of the window the bounds read whole, oldest first, in how many reads and how long. The operator's
    /// 30-day Gmail of 2026-10-27 (about 900 events an hour) stopped after about 9 days: said up front now.
    @Test func howFarAWideReadWillGet() {
        let operators = IncidentLogs.Estimate.from(count: 1_000, span: 4_000, took: 2, windowHours: 720, cap: 1_000, perDay: 100, budget: 200)
        #expect(operators.perHour == 900 && operators.hours == 222 && !operators.whole && !operators.tooBusy)
        #expect(operators.reads == 200 && operators.seconds == 400)
        let quiet = IncidentLogs.Estimate.from(count: 1_000, span: 360_000, took: 1.5, windowHours: 720, cap: 1_000, perDay: 100, budget: 200)
        #expect(quiet.perHour == 10 && quiet.whole && quiet.hours == 720 && quiet.reads == 9)
        let busy = IncidentLogs.Estimate.from(count: 1_000, span: 300, took: 2, windowHours: 720, cap: 1_000, perDay: 100, budget: 200)
        #expect(busy.perHour == 12_000 && busy.tooBusy && busy.hours == 0 && busy.reads == 1)
    }

    /// Exports put together: rows newest first, an event both saved once, the widest window, every account when any export
    /// was; a log stopped at its cap only while every export of it was (a later read for just the accounts that matter
    /// reaches further back). One that can't be read is named, the rest still read.
    @Test func exportsArePutTogether() async {
        let capped = "Over the last 30 days.\nAccounts: every account.\nFrom IP address: any.\nlogin-log.csv: the Sign-ins (user log) log, 1 events; older events past the cap weren't read.\n"
        let whole = "Over the last 7 days.\nAccounts: carol@example.com.\nFrom IP address: any.\nlogin-log.csv: the Sign-ins (user log) log, 2 events.\n"
        let first = Self.export("Incident logs 2026-10-23 0619", about: capped, login: [Self.late])
        let second = Self.export("Incident logs 2026-10-23 0700", about: whole, login: [Self.late, Self.early])
        let together = await IncidentLogs.evidence([first, second])
        let rows = (try? together.pull.logs.first?.rows.get()) ?? []
        #expect(rows.map(\.time) == ["2026-10-22T09:00:00Z", "2026-10-19T13:00:00Z"], "the repeat counted once, newest first")
        #expect(together.pull.logs.first?.capped == false && together.pull.query.hours == 720 && together.pull.query.users.isEmpty)
        #expect(await IncidentLogs.evidence([first, first]).pull.logs.first?.capped == true, "still at the cap in every export")
        let broken = ActivityLogs.Export(name: "Broken", about: whole, logs: [(.login, "name,actor.email\n")])
        let partly = await IncidentLogs.evidence([broken, first])
        #expect(partly.unreadable == ["Broken"] && ((try? partly.pull.logs.first?.rows.get().count) ?? 0) == 1)
    }

    /// More saved logs than are read back at once (`readBackAtOnce`): every one is read, each in its own place, an export
    /// that can't be read named, and the whole is what reading each export alone and putting them together gives.
    @Test func moreSavedLogsThanAreReadAtOnce() async throws {
        let about = "Over the last 3 days.\nAccounts: every account.\nFrom IP address: any.\n"
        let exports = (0..<6).map { n in
            ActivityLogs.Export(name: "Incident logs \(n)", about: about, logs: [
                (.login, Self.header + "login,2026-10-2\(n)T09:00:00Z,carol@example.com,login_success,192.0.2.\(n),,,\r\n"),
                (.token, n == 4 ? "name,actor.email\n" : Self.header + "token,2026-10-2\(n)T09:05:00Z,carol@example.com,authorize,,,,app_name: App \(n)\r\n"),
            ])
        }
        #expect(exports.count * 2 > IncidentLogs.readBackAtOnce)
        let read = await IncidentLogs.evidence(exports)
        let alone = IncidentLogs.merged(exports.compactMap(IncidentLogs.pull(of:)))
        #expect(read.unreadable == ["Incident logs 4"] && read.pull.logs.map(\.application) == [.login, .token])
        for (mine, theirs) in zip(read.pull.logs, alone.logs) { #expect(try mine.rows.get() == theirs.rows.get(), "\(mine.application)") }
        #expect(try read.pull.logs[0].rows.get().map(\.ip) == ["192.0.2.5", "192.0.2.3", "192.0.2.2", "192.0.2.1", "192.0.2.0"])
    }

    /// Several pulls put together at once (2026-10-24, so an incident's saved pulls are merged once, not after each) give
    /// what adding each to those before it gave, by the two-at-a-time merge kept here as the reference: the same rows in
    /// the same order (a tie in the order the pulls were made, a repeat inside one pull kept), caps, windows and accounts.
    @Test func pullsPutTogetherAtOnceAreThemAddedOneByOne() throws {
        func before(_ older: IncidentLogs.Pull, _ newer: IncidentLogs.Pull) -> IncidentLogs.Pull {
            var logs: [IncidentLogs.Log] = []
            for application in ActivityLogs.Application.allCases {
                let old = older.logs.first { $0.application == application }, new = newer.logs.first { $0.application == application }
                switch (old, new) {
                case (let old?, let new?):
                    switch (old.rows, new.rows) {
                    case (.success(let kept), .success(let read)):
                        let known = Set(kept.map(\.identity))
                        let rows = (kept + read.filter { !known.contains($0.identity) }).enumerated().sorted { a, b in
                            (a.element.date ?? .distantPast, b.offset) > (b.element.date ?? .distantPast, a.offset)
                        }.map(\.element)
                        logs.append(IncidentLogs.Log(application: application, rows: .success(rows), hours: max(old.hours, new.hours),
                                                     capped: old.capped && new.capped,
                                                     through: old.capped && new.capped ? [old.through, new.through].compactMap { $0 }.max() : nil))
                    case (.success, .failure): logs.append(old)
                    default: logs.append(new)
                    }
                case (let only?, nil), (nil, let only?): logs.append(only)
                case (nil, nil): break
                }
            }
            var seen: Set<String> = []
            let users = older.query.users.isEmpty || newer.query.users.isEmpty ? []
                : (older.query.users + newer.query.users).filter { seen.insert($0.lowercased()).inserted }
            return IncidentLogs.Pull(query: IncidentLogs.Query(applications: logs.map(\.application), users: users,
                                                               hours: max(older.query.hours, newer.query.hours),
                                                               ip: older.query.ip.isEmpty ? newer.query.ip : older.query.ip),
                                     logs: logs, ended: older.ended && newer.ended, fromEvidence: older.fromEvidence && newer.fromEvidence)
        }
        func rows(_ lines: [String]) throws -> [ActivityLogs.Row] {
            try #require(ActivityLogs.rows(exported: Self.header + lines.map { $0 + "\r\n" }.joined(), application: .login))
        }
        let tie = "login,2026-10-20T08:00:00Z,dana@example.com,login_success,192.0.2.10,,,"
        let undated = "login,soon,erin@example.com,login_failure,,,,"
        let at = { (time: String) in try? Date(time, strategy: .iso8601) }
        let failed = IncidentLogs.Log(application: .token, rows: .failure(UserAccess.Problem(summary: "Couldn't read it")), hours: 72, capped: false)
        func token(_ line: String) throws -> IncidentLogs.Log {
            IncidentLogs.Log(application: .token, rows: .success(try #require(ActivityLogs.rows(exported: Self.header + line + "\r\n", application: .token))),
                             hours: 72, capped: false)
        }
        let pulls = [
            IncidentLogs.Pull(query: IncidentLogs.Query(applications: [.login, .token], users: ["carol@example.com"], hours: 72, ip: ""),
                              logs: [IncidentLogs.Log(application: .login, rows: .success(try rows([Self.late, tie, Self.early, Self.early])),
                                                      hours: 72, capped: true, through: at("2026-10-21T00:00:00Z")),
                                     try token("token,2026-10-19T13:01:00Z,carol@example.com,authorize,198.51.100.23,,,app_name: Mail Sync Pro")],
                              ended: true),
            IncidentLogs.Pull(query: IncidentLogs.Query(applications: [.token, .login], users: ["Carol@example.com", "dana@example.com"], hours: 240, ip: "198.51.100.23"),
                              logs: [failed, IncidentLogs.Log(application: .login, rows: .success(try rows([tie.replacingOccurrences(of: "dana", with: "fay"), undated, Self.early])),
                                                              hours: 240, capped: true, through: at("2026-10-22T00:00:00Z"))],
                              ended: true, fromEvidence: true),
            IncidentLogs.Pull(query: IncidentLogs.Query(applications: [.gmail, .login], users: ["dana@example.com"], hours: 24, ip: "192.0.2.10"),
                              logs: [IncidentLogs.Log(application: .gmail, rows: .failure(UserAccess.Problem(summary: "No Gmail log")), hours: 24, capped: false),
                                     IncidentLogs.Log(application: .login, rows: .success(try rows([Self.late, tie])), hours: 24, capped: false)],
                              ended: true, fromEvidence: true),
        ]
        // Rows by their bytes (`String ==` takes "é" and "e" + U+0301 as equal); a failed read by its words.
        func bytes(_ log: IncidentLogs.Log) -> [[UInt8]] {
            switch log.rows {
            case .success(let rows): rows.map { Array(($0.identity + "\u{0}" + $0.id).utf8) }
            case .failure(let problem): [Array(problem.summary.utf8)]
            }
        }
        func same(_ a: IncidentLogs.Pull, _ b: IncidentLogs.Pull) -> Bool {
            a.query == b.query && a.ended == b.ended && a.fromEvidence == b.fromEvidence && a.logs.count == b.logs.count
                && zip(a.logs, b.logs).allSatisfy { x, y in
                    x.application == y.application && bytes(x) == bytes(y) && x.hours == y.hours && x.capped == y.capped && x.through == y.through
                }
        }
        for count in 2...pulls.count {
            for start in 0...(pulls.count - count) {
                let these = Array(pulls[start..<(start + count)])
                #expect(same(IncidentLogs.merged(these), these.dropFirst().reduce(these[0], before)), "pulls \(start)..<\(start + count)")
            }
        }
        // The cases it covers: a tie kept in the pulls' order, a repeat inside one pull kept, an undated row last, a log read
        // whole by one pull (not capped), a log one pull couldn't read taken from another, and every account when any was.
        let all = IncidentLogs.merged(pulls)
        let login = try #require(all.logs.first { $0.application == .login }).rows.get()
        #expect(login.map(\.who) == ["carol@example.com", "dana@example.com", "fay@example.com", "carol@example.com", "carol@example.com", "erin@example.com"])
        #expect(all.logs.first { $0.application == .login }?.capped == false && all.query.users == ["carol@example.com", "dana@example.com"])
        #expect(try all.logs.first { $0.application == .token }?.rows.get().count == 1 && all.query.ip == "198.51.100.23")
        #expect(IncidentLogs.merged(Array(pulls.prefix(2))).logs.first { $0.application == .login }?.through == at("2026-10-22T00:00:00Z"))
        // Each log's counts, made with it: the flagged events and the accounts, the same as counting its rows.
        for log in all.logs {
            let read = (try? log.rows.get()) ?? []
            #expect(log.flagged == read.filter(\.flagged).count && log.accounts == Set(read.map(\.who)).count, "\(log.application)")
        }
        #expect(all.logs.first { $0.application == .login }.map { [$0.flagged, $0.accounts] } == [2, 4] && failed.accounts == 0)
    }

    /// Show the Events: an account's events, from some addresses, in some logs, through an app or by an agent; a log with
    /// none of them is left out, and the narrowing is said in words.
    @Test func aFilterKeepsWhatAToDoItemIsAbout() async throws {
        let rows = ActivityLogs.rows(exported: Self.header + [Self.early, Self.late,
            "login,2026-10-19T13:05:00Z,dana@example.com,login_success,198.51.100.23,,through Mail Sync Pro,"].map { $0 + "\r\n" }.joined(),
                                     application: .login) ?? []
        let log = try #require(await IncidentLogs.evidence([Self.export("e", about: "Over the last 3 days.\n", login: [Self.early, Self.late,
            "login,2026-10-19T13:05:00Z,dana@example.com,login_success,198.51.100.23,,through Mail Sync Pro,"])]).pull.logs.first)
        let carol = IncidentLogs.Filter(accounts: ["Carol@example.com"], addresses: ["198.51.100.23"])
        #expect(rows.filter(carol.keeps).map(\.time) == ["2026-10-19T13:00:00Z"], "case aside, from that address only")
        #expect(try carol.applied(to: log)?.rows.get().count == 1)
        let app = IncidentLogs.Filter(accounts: ["dana@example.com"], apps: ["Mail Sync Pro"])
        #expect(rows.filter(app.keeps).count == 1 && rows.filter(IncidentLogs.Filter(accounts: [], agent: "an AI agent").keeps).isEmpty)
        #expect(IncidentLogs.Filter(accounts: ["carol@example.com"], applications: [.gmail]).applied(to: log) == nil, "another log")
        #expect(IncidentLogs.Filter(accounts: ["erin@example.com"]).applied(to: log) == nil, "none of its rows")
        #expect(carol.words == "Carol@example.com's events from 198.51.100.23")
        #expect(IncidentLogs.Filter(accounts: ["carol@example.com", "dana@example.com"], applications: [.gmail, .login], apps: ["Zoom"]).words
                == "carol@example.com and dana@example.com's events, in Gmail and Sign-ins (user log), through Zoom")
    }
}
