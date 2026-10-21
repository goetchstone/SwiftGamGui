import Foundation

/// A person's Chrome profiles (`GamCommands.printChromeProfiles`): each Chrome profile signed in with their work account
/// that Google knows of, where it is, which Chrome, and when it was last used. Answers "does this person use Chrome with
/// their work account?". It never shows what a profile holds: Google gives no one a person's saved passwords.
public enum ChromeProfiles {
    public struct Profile: Sendable, Equatable, Identifiable {
        /// `customers/<customer>/profiles/<permanent ID>`.
        public let id: String
        /// The name Chrome shows for the profile, as the person set it.
        public let displayName: String
        public let userEmail: String
        /// The computer's name, or its model where the name isn't reported.
        public let device: String
        /// "MAC 15.6", "WINDOWS 11", as Chrome reports them.
        public let system: String
        /// "141.0.7390.66 (stable)".
        public let browser: String
        /// When the profile was last used and first reported, as GAM printed them, and as dates when they read as ones.
        public let lastActivity: String
        public let lastActive: Date?
        public let firstEnrollment: String
        public let firstEnrolled: Date?
        /// Whether the computer is managed by this organization too (`AFFILIATED_…`), or only the profile.
        public let affiliation: String

        public init(record: GamOutput.Record) {
            func text(_ key: String) -> String { Fields.text(record[key]) }
            id = text("name")
            displayName = text("displayName")
            userEmail = text("userEmail")
            let info = record["deviceInfo"]?.object ?? [:]
            let hostname = Fields.text(info["hostname"]), machine = Fields.text(info["machine"])
            device = hostname.isEmpty ? machine : hostname
            system = [text("osPlatformType"), text("osVersion")].filter { !$0.isEmpty }.joined(separator: " ")
            let version = text("browserVersion"), channel = text("browserChannel")
            browser = channel.isEmpty ? version : "\(version) (\(channel.lowercased()))"
            lastActivity = text("lastActivityTime")
            lastActive = ChromeProfiles.date(lastActivity)
            firstEnrollment = text("firstEnrollmentTime")
            firstEnrolled = ChromeProfiles.date(firstEnrollment)
            affiliation = text("affiliationState")
        }

        /// The computer is one this organization manages (`AFFILIATED_…`; not `UNAFFILIATED_…`).
        public var onManagedDevice: Bool { affiliation.hasPrefix("AFFILIATED") }
    }

    /// What to do when GAM's authorization lacks the scope: said only for that failure (exit 15, no Chrome Management
    /// scope at all, or a scope refusal), never for one a new scope can't fix.
    public static let scopeNote = "This domain's GAM authorization needs the “Chrome Management API – Profiles” scope (read-only "
        + "is enough): authorize again from Setup's fresh setup with that scope ticked."

    /// The read failed for want of a scope (`scopeNote`).
    public static func needsScope(_ error: GamError) -> Bool {
        error.exitCode == 15 || error.kind == .scopeMissing
    }

    /// GAM's time with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
    }

    /// A finished read's profiles, the most recently used first: none is GAM's header line alone, exit 0. Throws the
    /// `GamError` when the read failed (exit 15: no Chrome Management scope; 50: the API refused it), and
    /// `MessageCopies.Incomplete` when GAM's output passed the runner's cap.
    public static func profiles(_ result: GamResult, argv: [String]) throws -> [Profile] {
        guard result.exitCode == 0 else {
            throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
        }
        guard !result.stdoutTruncated else {
            throw MessageCopies.Incomplete(reason: "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so the profiles weren't all read.")
        }
        return GamOutput.records(result.stdout).map(Profile.init(record:)).enumerated().sorted { a, b in
            (a.element.lastActive ?? .distantPast, b.offset) > (b.element.lastActive ?? .distantPast, a.offset)
        }.map(\.element)
    }
}
