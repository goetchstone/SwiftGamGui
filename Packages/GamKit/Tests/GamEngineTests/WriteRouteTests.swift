import Foundation
import Testing
import TestSupport

/// Invariant 2's structural half, as a source scan (the native port of GamGUI's
/// `test_write_routes_guarded.py`; its bare-confirm, edited-form and replay cases arrive with ChangeCore's
/// executor). Access levels close most routes to a credentialed `gam` at compile time; this closes the
/// ones the compiler can't see: another process start, another source of commands, another caller of
/// the raw runner.
@Suite("Write routes")
struct WriteRouteTests {
    static let root = Fixtures.repoRoot

    /// Every Swift file under `directory`, as (path relative to the repo, code lines without comments).
    static func swiftFiles(in directory: String) throws -> [(path: String, lines: [String])] {
        let base = root.appending(path: directory)
        let paths = try #require(FileManager.default.subpathsOfDirectory(atPath: base.path) as [String]?)
        return try paths.filter { $0.hasSuffix(".swift") }.sorted().map { path in
            let text = try String(contentsOf: base.appending(path: path), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            return ("\(directory)/\(path)", code)
        }
    }

    static func files(in directory: String, matching needles: [String], orWord word: String? = nil) throws -> Set<String> {
        Set(try swiftFiles(in: directory).filter { file in
            file.lines.contains { line in
                needles.contains { line.contains($0) } || word.map { line.contains(try! Regex("\\b\($0)\\b")) } == true
            }
        }.map(\.path))
    }

    /// Any use of Foundation's `Process` type, however spelled (`Process()`, `: Process = .init()`,
    /// `Process.launchedProcess`), plus the lower-level and indirect ways to start a program.
    static let processWord = "Process"
    static let processStarts = ["posix_spawn", "NSTask", "execv", "execl", "popen(", "system(", "fork(", "dlopen(",
                                "dlsym(", "NSUserUnixTask", "NSUserScriptTask", "NSUserAppleScriptTask",
                                "NSUserAutomatorTask", "NSAppleScript", "OSAScript", "OSAKit", "LSOpen",
                                "openApplication", "launchApplication", "SMAppService", "NSXPCConnection", "xpc_"]
    /// Reinterpreting memory would forge a `GamRead` from a write's argv.
    static let memoryCasts = ["unsafeBitCast", "unsafeDowncast", "withMemoryRebound", "assumingMemoryBound",
                              "bindMemory", "unsafeAddress"]

    @Test func onlyGamRunnerStartsAProcess() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: Self.processStarts, orWord: Self.processWord)
                == ["Packages/GamKit/Sources/GamEngine/GamRunner.swift"])
        #expect(try Self.files(in: "App", matching: Self.processStarts, orWord: Self.processWord).isEmpty)
    }

    @Test func onlyTheBuildersMintCommands() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["GamRead(", "GamWrite("])
                == ["Packages/GamKit/Sources/GamEngine/GamCommands.swift"])
        #expect(try Self.files(in: "App", matching: ["GamRead(", "GamWrite("]).isEmpty)
    }

    /// The Builder (invariants 2 and 3): only its screen runs a catalog read (a `GamRead` from `GamCommands.catalogRead`, which
    /// refuses any command that isn't runnable), and its changes reach ChangeCore through `BuilderChanges` alone: the screen names
    /// no other changes model, no executor or write, and confirms nothing (its sheet does, `onlyAScreenMakesTheOperatorsConfirmation`).
    @Test func theBuilderWritesOnlyThroughBuilderChanges() throws {
        #expect(try Self.files(in: "App", matching: ["catalogRead"]) == ["App/BuilderView.swift"])
        let writing = try Self.files(in: "App", matching: ["UserChanges", "GroupChanges", "groupChanges", "CalendarChanges",
                                                           "SignatureChanges", "OnboardChanges", "OffboardChanges", "CompromisedChanges",
                                                           "PhishingChanges", "Executor", "executor", "GamWrite", "WriteStep",
                                                           "AuthenticatedRunner", "AppServices", "HeldPreview", ".confirm(", "confirmed:"],
                                     orWord: "OperatorConfirmation")
        #expect(!writing.contains("App/BuilderView.swift"), "\(writing)")
        let reaching = try Self.files(in: "App", matching: ["BuilderChanges", "builderChanges"])
        #expect(reaching == ["App/AppServices.swift", "App/BuilderView.swift", "App/ChangePreviewSheet.swift", "App/GamGUIApp.swift"],
                "\(reaching)")
    }

    /// Plan F1: the read record is no write path (invariant 2). `ReadAudit` holds an audit log and nothing else, so it can run no
    /// `gam` and reach no ticket, and it writes one action, `read`. Only the Builder's door (`UserAccess.catalogRead`) and an audit
    /// run's step (`AuditRunner`, plan F3) record a read; in the app only the wiring makes the recorder and only the Builder hands
    /// it on (and the debug demo's log names one).
    @Test func theReadRecordIsNoWritePath() throws {
        let file = try #require(try Self.swiftFiles(in: "Packages/GamKit/Sources/ChangeCore").first { $0.path.hasSuffix("/ReadAudit.swift") })
        #expect(Set(file.lines.filter { $0.hasPrefix("import ") }) == ["import Foundation", "import GamEngine", "import Vault"])
        let reaching = ["Runner", "runner", "WriteTicket", "ticket:", "Executor", "GamWrite", "GamRead", "WriteStep", "HeldPreview",
                        ".run(", "Process", "Confirmation"]
        #expect(file.lines.filter { line in reaching.contains { line.contains($0) } }.isEmpty)
        let records = file.lines.filter { $0.contains(".record(") }
        #expect(records.count == 1 && records.allSatisfy { $0.contains("log.record(Self.action,") }, "\(records)")
        #expect(file.lines.contains { $0.contains(#"public static let action = "read""#) })
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["ReadAudit"])
                == ["Packages/GamKit/Sources/ChangeCore/ReadAudit.swift", "Packages/GamKit/Sources/Directory/AuditRunner.swift",
                    "Packages/GamKit/Sources/Directory/UserAccess.swift"])
        #expect(try Self.files(in: "App", matching: ["ReadAudit", "readAudit"])
                == ["App/AppServices.swift", "App/BuilderView.swift", "App/DemoAudit.swift", "App/GamGUIApp.swift"])
    }

    /// Plan F3: an audit run is no write path (invariant 2, GamGUI's `/reports/runs/start` in its LOCAL_ONLY list). Its runner and
    /// its tables reach no executor, write or ticket; each step's read is its run's own builder (`AuditRuns.read`), and only a
    /// `print` read without `todrive` runs (`AuditRuns.isAuditRead`, checked before GAM). The run's one write, Suspend these…, is
    /// `InactiveSuspend`, through the executor like every other.
    @Test func anAuditRunIsNoWritePath() throws {
        let files = try Self.swiftFiles(in: "Packages/GamKit/Sources/Directory").filter {
            $0.path.hasSuffix("/AuditRunner.swift") || $0.path.hasSuffix("/AuditRuns.swift")
        }
        #expect(files.count == 2)
        let reaching = ["WriteTicket", "ticket:", "Executor", "executor", "GamWrite", "WriteStep", "HeldPreview", "Confirmation",
                        "Process", "catalogRead"]
        for file in files {
            #expect(file.lines.filter { line in reaching.contains { line.contains($0) } }.isEmpty, "\(file.path)")
        }
        let runner = try #require(files.first { $0.path.hasSuffix("/AuditRunner.swift") })
        let runs = runner.lines.filter { $0.contains("runner.run(") }
        #expect(runs.count == 1 && runs.allSatisfy { $0.contains("runner.run(read, as: domain") }, "\(runs)")
        #expect(runner.lines.contains { $0.contains("if let gam = AuditRuns.read(step, tables: tables)") })
        #expect(runner.lines.contains { $0.contains("guard AuditRuns.isAuditRead(read.argv) else") })
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["InactiveSuspend"]) == ["Packages/GamKit/Sources/Directory/InactiveSuspend.swift"])
    }

    /// The jobs tray reaches no write: the Jobs module depends on nothing in GamKit, its screen imports only it and SwiftUI, and
    /// only the app's wiring gives it a Stop (the executor's `stopAfterCurrentStep`, which never runs anything).
    @Test func theJobsTrayReachesNoWrite() throws {
        let manifest = try String(contentsOf: Self.root.appending(path: "Packages/GamKit/Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".target(name: "Jobs"),"#), "Jobs gains no dependency")
        let imports = try Self.swiftFiles(in: "App").first { $0.path == "App/JobsView.swift" }?.lines.filter { $0.hasPrefix("import ") }
        #expect(imports.map(Set.init) == ["import Jobs", "import SwiftUI"])
        #expect(try Self.files(in: "App", matching: ["stopRun ="]) == ["App/AppServices.swift"])
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["stopRun ="]).isEmpty)
    }

    /// `GamRunner.runRaw` takes any argv, and without a config directory GAM falls back to `~/.gam`
    /// (the operator's own GAM, if any). Only the authenticated runner (credentials) and the version probe
    /// (an empty config) call it, and only they make a config directory.
    @Test func onlyTheRunnersCallTheRawRunner() throws {
        let runners: Set = ["Packages/GamKit/Sources/GamEngine/AuthenticatedRunner.swift",
                            "Packages/GamKit/Sources/GamEngine/GamVersion.swift"]
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["runRaw("])
                == runners.union(["Packages/GamKit/Sources/GamEngine/GamRunner.swift"]))
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["materialize("])
                == runners.union(["Packages/GamKit/Sources/GamEngine/EphemeralConfig.swift"]))
    }

    @Test func theAppNeverReinterpretsMemory() throws {
        #expect(try Self.files(in: "App", matching: Self.memoryCasts).isEmpty)
    }

    /// Invariant 2: the runner's write entry takes a `WriteTicket`, and only ChangeCore's executor makes
    /// one, after a held preview passed every check. A ticket anywhere else is a second write path.
    /// By word, not by `WriteTicket(`: `.init()` with a `ticket:` label minted one unseen (ChangeCore's
    /// review). Only the definition, the runner's parameter and the executor may name it.
    @Test func onlyTheExecutorMintsAWriteTicket() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["WriteTicket", "ticket:"])
                == ["Packages/GamKit/Sources/ChangeCore/ChangeCore.swift",
                    "Packages/GamKit/Sources/GamEngine/AuthenticatedRunner.swift",
                    "Packages/GamKit/Sources/GamEngine/GamCommand.swift"])
        #expect(try Self.files(in: "App", matching: ["WriteTicket", "ticket:"]).isEmpty)
    }

    /// Invariant 10: a model or Siri only drafts. The operator's confirmation is made in a confirm screen,
    /// never in GamKit and never in code that also speaks to Siri or a model (an intent confirming its own
    /// draft). The executor also demands a Confirm click for every non-form preview.
    @Test func onlyAScreenMakesTheOperatorsConfirmation() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["OperatorConfirmation("]).isEmpty)
        // By word, and by the `.init(confirmed:)` spelling, which never names the type.
        let confirming = try Self.files(in: "App", matching: ["confirmed:", ".confirm("], orWord: "OperatorConfirmation")
        #expect(confirming == ["App/ChangePreviewSheet.swift"], "only the confirm sheet confirms: \(confirming)")
        let voiceOrModel = try Self.files(in: "App", matching: ["AppIntent", "FoundationModels", "LanguageModel", "Assist"])
        #expect(confirming.isDisjoint(with: voiceOrModel))
    }

    /// Invariant 10 for a domain switch (plan F6's review): agreeing to stop the runs going now (an offboarding or a Secure left
    /// half done) is the operator's, given on a screen that showed what stops, as a confirmation is. Only Setup takes it, only
    /// the domain menu's panel and Setup pass it, only `AppServices` says what's running, and no file that speaks to Siri or
    /// a model reaches any of it.
    @Test func onlyAScreenAgreesToStopRuns() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["agreedToStop"])
                == ["Packages/GamKit/Sources/Setup/SetupModel.swift"])
        let agreeing = try Self.files(in: "App", matching: ["agreedToStop", "switchAnyway", "runIDs"])
        #expect(agreeing == ["App/DomainMenuView.swift", "App/SetupView.swift"], "\(agreeing)")
        #expect(try Self.files(in: "App", matching: ["runningRuns", "SwitchStops"]) == ["App/AppServices.swift"])
        let voiceOrModel = try Self.files(in: "App", matching: ["AppIntent", "FoundationModels", "LanguageModel", "Assist"])
        #expect(agreeing.isDisjoint(with: voiceOrModel) && !voiceOrModel.contains("App/AppServices.swift"))
    }

    /// Invariant 10, the other half: code that speaks to Siri or a model reaches no write at all, not even
    /// a preview. It hands its words to the screens (`SiriDrafts`), which draft the preview the operator
    /// confirms; the executor then demands the Confirm click for it.
    @Test func noIntentReachesAWrite() throws {
        let voiceOrModel = try Self.files(in: "App", matching: ["AppIntent", "FoundationModels", "LanguageModel", "Assist"])
        let writing = try Self.files(in: "App", matching: ["UserChanges", "userChanges", "OnboardChanges", "onboardChanges",
                                                           "OffboardChanges", "offboardChanges", "CompromisedChanges", "compromisedChanges",
                                                           "BuilderChanges", "builderChanges", "Executor", "executor", ".confirm(",
                                                           "confirmed:", "WriteStep", "GamWrite", "AuthenticatedRunner",
                                                           "previewOrganization", "previewPhone", "AppServices", "HeldPreview", "Origin",
                                                           ".run("], orWord: "OperatorConfirmation")
        #expect(voiceOrModel.isDisjoint(with: writing), "\(voiceOrModel.intersection(writing))")
        #expect(voiceOrModel.contains { $0.hasSuffix("SiriIntents.swift") }, "the scan must see the intents")
        // What the intents are given is the drafts, and only there; the drafts themselves reach no write.
        #expect(try Self.files(in: "App", matching: ["AppDependencyManager", "@Dependency"]) == ["App/SiriIntents.swift"])
        #expect(!writing.contains("App/SiriDrafts.swift"))
    }

    /// Invariant 10 for the log reader (docs/plans/2026-10-19-on-device-log-reader.md): the module that talks to the model
    /// depends on nothing in GamKit, so nothing it holds can run gam, and its one screen hands a fix to another screen
    /// as an address or a Message-ID (it is among `noIntentReachesAWrite`'s model files, which reach no write).
    @Test func theLogReaderCanRunNothing() throws {
        let manifest = try String(contentsOf: Self.root.appending(path: "Packages/GamKit/Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".target(name: "Assist"),"#), "Assist gains no dependency")
        let imports = try Self.swiftFiles(in: "Packages/GamKit/Sources/Assist").flatMap(\.lines).filter { $0.hasPrefix("import ") }
        #expect(Set(imports).isSubset(of: ["import Foundation", "import FoundationModels"]), "\(imports)")
        #expect(try Self.files(in: "App", matching: ["LogReading", "LogExplainer"]) == ["App/LogReaderView.swift"])
        #expect(try Self.files(in: "App", matching: ["AppIntent", "FoundationModels", "LanguageModel", "Assist"])
            .contains("App/LogReaderView.swift"), "the scan must see the reader")
    }

    /// The connected apps' summary is code's own sentences: its model was retired (plan 2026-11-18, R1), and the panel
    /// talks to no model again unless someone means it to.
    @Test func theConnectedAppsPanelTalksToNoModel() throws {
        #expect(try !Self.files(in: "App", matching: ["AppIntent", "FoundationModels", "LanguageModel", "Assist"])
            .contains("App/ConnectedAppsView.swift"))
        #expect(try Self.files(in: "App", matching: ["AppsExplainer"]).isEmpty)
    }

    /// The model is the one on this Mac (plan 2026-11-18, A1). macOS 27's `LanguageModelSession(model: some LanguageModel, …)`
    /// takes `PrivateCloudComputeLanguageModel` as well, so one changed word would send tenant accounts and addresses off the
    /// Mac with every other test green. Every line naming a session makes it from `SystemLanguageModel.default` (a session
    /// split across lines, or made with `.init`, fails too), only in `Assist`, which reaches no network itself.
    @Test func theModelIsOnThisMacOnly() throws {
        let code = try Self.swiftFiles(in: "App") + Self.swiftFiles(in: "Packages/GamKit/Sources")
        let offMac = code.filter { $0.lines.contains { $0.contains("PrivateCloudCompute") } }.map(\.path)
        #expect(offMac.isEmpty, "\(offMac)")
        let sessions = code.flatMap { file in file.lines.filter { $0.contains("LanguageModelSession") }.map { (file.path, $0) } }
        #expect(!sessions.isEmpty, "the scan must see the log explainer's session")
        for (path, line) in sessions {
            #expect(path.hasPrefix("Packages/GamKit/Sources/Assist/"), "\(path): \(line)")
            #expect(line.contains("LanguageModelSession(model: SystemLanguageModel.default"), "\(path): \(line)")
        }
        // Foundation reaches the network without an import the check above sees: a session, a request, or reading a URL.
        #expect(try Self.files(in: "Packages/GamKit/Sources/Assist", matching: ["URLSession", "URLRequest", "NSURLConnection", "contentsOf:"])
            .isEmpty)
    }

    /// The compromised-account model is reached from its own screen, its confirm sheet and the wiring only: Users'
    /// "Secure Account…" hands over an address, never a preview.
    @Test func onlyItsScreenReachesTheCompromisedModel() throws {
        let reaching = try Self.files(in: "App", matching: ["CompromisedChanges", "compromisedChanges"])
        #expect(reaching == ["App/AppServices.swift", "App/ChangePreviewSheet.swift", "App/CompromisedView.swift", "App/GamGUIApp.swift"],
                "\(reaching)")
    }

    /// Signature backups (GamGUI's #163, #164): only the executor starts a kept run and keeps into it, in the write lock,
    /// after the exact read; a screen or a model only reads what was kept and puts it back through a preview. Only the
    /// app's wiring hands the executor its keeper.
    @Test func onlyTheExecutorKeepsSignatures() throws {
        let keeping = [".keep(email:", ".start(what:", "KeptSignatureRun"]
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: keeping)
                == ["Packages/GamKit/Sources/ChangeCore/ChangeCore.swift", "Packages/GamKit/Sources/ChangeCore/SignatureKeeping.swift",
                    "Packages/GamKit/Sources/Stores/SignatureBackupStore.swift"])
        #expect(try Self.files(in: "App", matching: keeping).isEmpty)
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["signatureKeeper:"]) == ["Packages/GamKit/Sources/ChangeCore/ChangeCore.swift"])
        #expect(try Self.files(in: "App", matching: ["signatureKeeper:"]).subtracting(["App/AppServices.swift"]).isEmpty)
    }

    /// Every signature a screen replaces is kept first: Signatures builds its writes in one place, each with its `KeepFirst`,
    /// and onboarding sets one on an account its run makes (which has none to keep) or keeps it first in a later run's retry.
    /// The executor refuses any other (`signatureNotKept`). The Builder's set_signature is Signatures'
    /// (`CuratedCommand.elsewhere`); the demo's audit only names one.
    @Test func everySignatureAScreenReplacesIsKeptFirst() throws {
        let setting = "GamCommands.setSignature("
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: [setting])
                == ["Packages/GamKit/Sources/ChangeCore/ChangeCore.swift", "Packages/GamKit/Sources/Directory/OnboardChanges.swift",
                    "Packages/GamKit/Sources/Directory/SignatureChanges.swift"])
        #expect(try Self.files(in: "App", matching: [setting]) == ["App/DemoAudit.swift"])
        let lines = try #require(try Self.swiftFiles(in: "Packages/GamKit/Sources/Directory")
            .first { $0.path.hasSuffix("/SignatureChanges.swift") }?.lines)
        let built = lines.indices.filter { lines[$0].contains(setting) }
        #expect(built.count == 1, "one place builds Signatures' writes")
        #expect(built.allSatisfy { $0 + 1 < lines.count
            && lines[$0 + 1].contains("keepFirst: .signature(email: email, setting: setting, expectedNow: expectedNow, restoring: restoring)") })
        // Onboarding's sets: on the account its own run creates (`creates`, `newAccountFrom`), or a later run's retry of that
        // step, which keeps first.
        let onboarding = try #require(try Self.swiftFiles(in: "Packages/GamKit/Sources/Directory")
            .first { $0.path.hasSuffix("/OnboardChanges.swift") }?.lines.joined(separator: "\n"))
        #expect(onboarding.components(separatedBy: setting).count - 1 == 2)
    }

    /// Offboarding's routine and the compromised-account lock are the previews only `requires` stops (a refused sign-out
    /// mustn't stop forwarding off), and the offboarding sweep the one step that counts benign failures as done
    /// (ChangeCore's additions A and B, the offboarding plan): no other caller loosens either.
    @Test func onlyTheRoutineLoosensTheRunsRules() throws {
        // Any mention, not only `: false` spelled out: a variable passed as the argument loosens it just the same.
        let core = "Packages/GamKit/Sources/ChangeCore/ChangeCore.swift", offboard = "Packages/GamKit/Sources/Directory/OffboardChanges.swift"
        let requiresOnly = try Self.files(in: "Packages/GamKit/Sources", matching: ["stopsAtAccountWideFailure"])
        #expect(requiresOnly.isSubset(of: [core, offboard, "Packages/GamKit/Sources/Directory/CompromisedChanges.swift"]), "\(requiresOnly)")
        let tolerating = try Self.files(in: "Packages/GamKit/Sources", matching: ["tolerating:"])
        #expect(tolerating.isSubset(of: [core, offboard]), "\(tolerating)")
        #expect(try Self.files(in: "App", matching: ["stopsAtAccountWideFailure", "tolerating:"]).isEmpty)
    }

    /// Invariant 4, design D4: a temporary password's text is read in one place, the sign-in card. Anywhere
    /// else (a row, a log line, a feed, an announcement) would show or keep it.
    @Test func onlyTheCardShowsATemporaryPassword() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["shownOnTheSheet"])
                == ["Packages/GamKit/Sources/GamEngine/Onboarding.swift"], "only its definition")
        #expect(try Self.files(in: "App", matching: ["shownOnTheSheet"]) == ["App/OnboardCredentialSheet.swift"])
    }

    /// The Vault's session ends with the screen's (plan 2026-11-18, S2): the app delegate watches the display's sleep, a
    /// switch of user and the screen lock, and the app hands it the Vault's lock alone.
    @Test func theVaultLocksWithTheScreen() throws {
        let delegate = try #require(try Self.swiftFiles(in: "App").first { $0.path == "App/AppDelegate.swift" }).lines.joined(separator: "\n")
        for name in ["NSWorkspace.screensDidSleepNotification", "NSWorkspace.sessionDidResignActiveNotification", "\"com.apple.screenIsLocked\""] {
            #expect(delegate.contains(name), "\(name)")
        }
        #expect(delegate.contains("lockTheVaultWithTheScreen()\n"), "called at launch")
        #expect(try Self.files(in: "App", matching: ["AppDelegate.lockVault = services.lockVault"]) == ["App/GamGUIApp.swift"])
    }

    /// The app reaches GamKit only through its public API: `@testable` would reopen every route.
    @Test func theAppNeverImportsGamKitTestably() throws {
        #expect(try Self.files(in: "App", matching: ["@testable"]).isEmpty)
    }

    /// The binary override reaches only the strict mock (failure-log 2026-11-18): `GamBinary` names it, and in the app only
    /// `AppServices.mockGam`, a debug-only check that it is the mock script, reads it. Its binary runs only in the demo
    /// (an in-memory Vault) and the spike (a throwaway Keychain service), and the real path, `make`, builds its runner from
    /// `GamBinary.locate()` alone. A second reader, or a `make` that fell back to the mock, could hand the real Keychain's
    /// credentials to a program the environment chose.
    @Test func onlyTheMockCheckReadsTheBinaryOverride() throws {
        let needles = ["overrideVariable", "\"SWIFTGAMGUI_GAM_BINARY\""]
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: needles)
                == ["Packages/GamKit/Sources/GamEngine/GamBinary.swift"])
        #expect(try Self.files(in: "App", matching: needles) == ["App/AppServices.swift"])
        let binary = try #require(try Self.swiftFiles(in: "Packages/GamKit/Sources").first { $0.path.hasSuffix("GamEngine/GamBinary.swift") })
        #expect(binary.lines.filter { $0.contains("overrideVariable") }.count == 1, "GamBinary declares the name and reads nothing")

        let app = try Self.swiftFiles(in: "App")
        /// Each line of the app that holds one of `needles`, as (file, the line, the function it sits in, the compiler directive
        /// governing it: the nearest `#if`, `#else`, `#elseif` or `#endif` above it, trimmed).
        func sites(_ needles: [String]) -> [(path: String, line: String, function: String, directive: String)] {
            app.flatMap { file in
                file.lines.indices.filter { i in needles.contains { file.lines[i].contains($0) } }.map { i in
                    let above = file.lines[..<i]
                    let function = above.last { $0.contains("func ") } ?? ""
                    let directive = above.map { $0.trimmingCharacters(in: .whitespaces) }
                        .last { line in ["#if", "#else", "#elseif", "#endif"].contains { line.hasPrefix($0) } } ?? ""
                    return (file.path, file.lines[i], function, directive)
                }
            }
        }
        let reads = sites(needles)
        #expect(reads.count == 1)
        for read in reads {
            #expect(read.function.contains("static func mockGam("))
            #expect(read.directive == "#if DEBUG", "mockGam is debug-only")
        }
        // Who runs the mock: the demo and the spike, both debug-only; never `make`.
        let mockUses = sites(["mockGam("]).filter { !$0.line.contains("func mockGam(") }
        #expect(Set(mockUses.map { "\($0.path) \($0.function.trimmingCharacters(in: .whitespaces))" }) == [
            "App/AppServices.swift private static func demo() -> AppServices {",
            "App/Spikes.swift static func vault() async {",
        ])
        // Who builds a runner: `make` (from `locate()`), the demo and the spike (from `mockGam()`).
        let runners = sites(["GamRunner("])
        #expect(Set(runners.map { "\($0.path) \($0.function.trimmingCharacters(in: .whitespaces))" }) == [
            "App/AppServices.swift static func make() -> AppServices {",
            "App/AppServices.swift private static func demo() -> AppServices {",
            "App/Spikes.swift static func vault() async {",
        ])
        let services = try #require(app.first { $0.path == "App/AppServices.swift" })
        let make = try #require(services.lines.firstIndex { $0.contains("static func make() -> AppServices {") })
        let makeEnd = try #require(services.lines[make...].firstIndex { $0 == "    }" })
        let makeBody = services.lines[make...makeEnd]
        #expect(makeBody.contains { $0.contains("GamBinary.locate()") })
        #expect(!makeBody.contains { $0.contains("mockGam") }, "the real path never falls back to the mock")
    }

    /// The scan must see the code it guards, or every check above passes vacuously.
    @Test func theScanSeesTheRunnerAndTheApp() throws {
        let sources = try Self.swiftFiles(in: "Packages/GamKit/Sources")
        #expect(sources.contains { $0.path.hasSuffix("GamEngine/GamRunner.swift") && $0.lines.contains { $0.contains("posix_spawn(") } })
        #expect(try Self.swiftFiles(in: "App").count > 5)
    }
}
