import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// A person's computers, read from Google's endpoint management (`GamCommands.printDevices`), and the Devices log in words,
/// against the strict mock (docs/domains/compromised-account.md, "Computers"). The mock's devices: carol has a virtual
/// machine registered the second after the suspect sign-in, her own MacBook Pro (re-registered that day) and a Pixel; alice
/// a MacBook Air; dana an old PC, blocked; and carol@example.com.au, whom Google's prefix search also answers for
/// carol@example.com, a ThinkPad.
@Suite("Devices")
struct DevicesTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    private func run(_ argv: [String], state: URL? = nil) async throws -> GamResult {
        let config = try Fixtures.placeholderConfigDirectory()
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = Fixtures.mockEnvironment
        if let state { environment["GAM_MOCK_STATE"] = state.path }
        let raw = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        // As the app's runner hands it on: without the first-run banner naming this call's config folder.
        return GamResult(exitCode: raw.exitCode, stdout: AuthenticatedRunner.withoutConfigNoise(raw.stdout, configDirectory: config),
                         stderr: raw.stderr, stdoutTruncated: raw.stdoutTruncated, stderrTruncated: raw.stderrTruncated)
    }

    private func computers(_ email: String, state: URL? = nil) async throws -> (GamResult, [Compromised.Computer]) {
        let result = try await run(try GamCommands.printDevices(user: email).argv, state: state)
        return (result, GamOutput.records(result.stdout).compactMap { Compromised.Computer(record: $0, owner: email) })
    }

    /// Only the person's own computers: not the prefix's other account, and not a phone (the phones list's). Each in words,
    /// a virtual machine called out, the person's own first sync, whose it is.
    @Test func aPersonsComputersAreTheirsAlone() async throws {
        let (result, carol) = try await computers("carol@example.com")
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(GamOutput.records(result.stdout).count == 4, "Google's prefix search answers carol@example.com.au too")
        #expect(carol.map(\.id) == ["devices/0vmcarol01", "devices/0maccarol01"])
        let machine = carol[0]
        #expect(machine.words == "Virtual Machine, Windows 10.0.19045 (Windows), named DESKTOP-7Q2LM4K")
        #expect(machine.looksVirtual && machine.ownership == "personal" && !machine.reportsCompromise)
        #expect(machine.firstSync == "2026-10-19T14:12:41Z" && machine.firstSynced != nil && machine.serialNumber == "0000-0000-1111-2222")
        // First signed in when she first did, not when she last registered (Google moves `firstSyncTime` each time).
        #expect(!carol[1].looksVirtual && carol[1].ownership == "the company's" && carol[1].firstSync == "2025-02-03T15:05:00Z")
        #expect(carol.allSatisfy { $0.isActive && $0.state.isEmpty })
        // A blocked device user stays listed until it's deleted: shown with its state, never counted as signed in.
        let dana = try await computers("dana@example.com").1
        #expect(dana.map(\.state) == ["blocked"] && dana.allSatisfy { !$0.isActive })
        let (_, alice) = try await computers("Alice@Example.com")
        #expect(alice.map(\.words) == ["MacBook Air, macOS 26.0 (macOS), named alice-air"], "the address in any case is the same person")
        #expect(try await computers("bob@example.com").1.isEmpty)
    }

    /// Without the devices scope GAM refuses before it reads an argument, each cause with its own fix: delegation not
    /// granted is the admin's "Service/App not enabled" (73), granted in the Admin console; a service account scope list
    /// without the API is "API access Denied" (12), which delegating can't fix, and wins when both are missing. A dead key is
    /// exit 12 too, and no scope's fault: no note.
    @Test func aMissingScopeIsSaidWithItsOwnFix() async throws {
        for (files, exit, note) in [(["noscope"], Int32(73), Compromised.Computer.delegationNote),
                                    (["denied"], 12, Compromised.Computer.scopeListNote),
                                    (["noscope", "denied"], 12, Compromised.Computer.scopeListNote), (["badkey"], 12, nil)] {
            let state = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-devices-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: state) }
            for file in files {
                try FileManager.default.createDirectory(at: state.appending(path: file), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: state.appending(path: "\(file)/devices").path, contents: Data())
            }
            let (result, found) = try await computers("carol@example.com", state: state)
            #expect(result.exitCode == exit && found.isEmpty && result.stdout.isEmpty, "\(files): \(result.stderr)")
            #expect(Compromised.Computer.note(for: GamError(exitCode: result.exitCode, stderr: result.stderr)) == note, "\(files)")
        }
        #expect(Compromised.Computer.note(for: GamError(exitCode: 50, stderr: "ERROR: something else\n")) == nil)
        #expect(Compromised.Computer.delegationNote.contains("https://www.googleapis.com/auth/cloud-identity.devices"))
    }

    /// A virtual machine by its model or its maker: Hyper-V's "Virtual Machine", VMware's EFI model, QEMU's, a cloud's.
    @Test func aVirtualMachineIsKnownByModelOrMaker() {
        func computer(_ model: String, _ maker: String) -> Compromised.Computer? {
            Compromised.Computer(record: ["deviceType": .string("WINDOWS"), "model": .string(model), "manufacturer": .string(maker),
                                          "users": .array([.object(["userEmail": .string("a@example.com")])])], owner: "a@example.com")
        }
        for (model, maker) in [("Virtual Machine", "Microsoft Corporation"), ("VMware7,1", "VMware, Inc."),
                               ("Standard PC (Q35 + ICH9, 2009)", "QEMU"), ("HVM domU", "Xen"), ("Google Compute Engine", "Google")] {
            #expect(computer(model, maker)?.looksVirtual == true, "\(model)")
        }
        #expect(computer("ThinkPad X1", "Lenovo")?.looksVirtual == false)
    }

    /// The mock holds the read to GAM's grammar: a query that isn't one `field:value`, a field not in the grammar, and the
    /// shapes the app never sends are refused, as GAM refuses them or as not modelled.
    @Test func theMockHoldsTheDeviceReadToTheGrammar() async throws {
        let read = try GamCommands.printDevices(user: "carol@example.com").argv
        for (argv, words) in [(["print", "devices", "query", "carol@example.com"] + Array(read.suffix(5)), "Invalid Device query"),
                              (Array(read.prefix(4)) + ["fields", "devicetype,colour"] + Array(read.suffix(3)), "Invalid choice"),
                              (Array(read.prefix(6)) + ["userfields", "useremail,shoesize", "formatjson"], "Invalid choice")] {
            let refused = try await run(argv)
            #expect(refused.exitCode == 2 && refused.stderr.contains(words), "\(argv): \(refused.stderr)")
        }
        let fields = try #require(read.firstIndex(of: "fields")), userFields = try #require(read.firstIndex(of: "userfields"))
        var noType = read, noEmail = read
        noType[fields + 1] = noType[fields + 1].replacingOccurrences(of: "devicetype,", with: "")
        noEmail[userFields + 1] = noEmail[userFields + 1].replacingOccurrences(of: "useremail,", with: "")
        for argv in [Array(read.dropLast()), read + ["company"], ["print", "devices", "query", "serial:123", "formatjson"], noType, noEmail] {
            let refused = try await run(argv)
            #expect(refused.exitCode == 2 && refused.stderr.contains("isn't modelled"), "\(argv): \(refused.stderr)")
        }
    }

    /// Check Account's sentence: how many computers, a virtual machine called out, what to do.
    @Test func computersAreSaidInTheFindings() async throws {
        let (_, carol) = try await computers("carol@example.com")
        // Enrolled in 2-Step Verification, so the computers are all there is to say.
        let account = Compromised.Account(GamUser(record: ["primaryEmail": .string("carol@example.com"), "isEnrolledIn2Sv": .bool(true)]))
        let said = Compromised.findings(account: account, forwarding: nil, filters: nil, delegates: nil, sendAs: nil, roles: nil,
                                        computers: carol)
        #expect(said == ["2 computers are signed in with carol@example.com's account, 1 of them a virtual machine: one they don't use "
                         + "may be the attacker's. The sign-out ends its session; block or delete it in the Admin console's Devices."])
        // One already blocked is said as such, and alone needs nothing.
        let dana = try await computers("dana@example.com").1
        #expect(Compromised.findings(account: account, forwarding: nil, filters: nil, delegates: nil, sendAs: nil, roles: nil,
                                     computers: carol + dana).first?.hasSuffix(" 1 more is already blocked or wiped.") == true)
        #expect(Compromised.findings(account: account, forwarding: nil, filters: nil, delegates: nil, sendAs: nil, roles: nil,
                                     computers: dana).isEmpty)
        #expect(Compromised.findings(account: account, forwarding: nil, filters: nil, delegates: nil, sendAs: nil, roles: nil,
                                     computers: Array(carol.prefix(1))).first?.hasPrefix("A computer is signed in with carol@example.com's account, and it's a virtual machine:") == true)
        #expect(Compromised.findings(account: account, forwarding: nil, filters: nil, delegates: nil, sendAs: nil, roles: nil,
                                     computers: []).isEmpty)
    }

    /// The Devices log in words: a registration says what joined, the device's own "Device" is no app acting, and an app that
    /// did sync it (Gmail's) is said.
    @Test func theDevicesLogIsSaid() async throws {
        let result = try await run(try GamCommands.reportActivity(.mobile, hours: 72, maxActivities: 100).argv)
        #expect(result.exitCode == 0, "\(result.stderr)")
        let rows = ActivityLogs.rows(result.stdout, application: .mobile)
        let joined = try #require(rows.first { $0.who == "carol@example.com" && $0.event == "DEVICE_REGISTER_UNREGISTER_EVENT" })
        #expect(joined.words == "Registered a device" && joined.app.isEmpty && joined.via.isEmpty)
        #expect(joined.details == ["Windows computer (Virtual Machine, Windows 10.0.19045)"])
        let dana = try #require(rows.first { $0.who == "dana@example.com" && $0.event == "DEVICE_SYNC_EVENT" })
        #expect(dana.words == "A device synced" && dana.via == "through Gmail iOS App")
        #expect(dana.details == ["iPhone or iPad (iPhone 16, iOS 26.0)", "through Gmail iOS App"])
        // Another event's own parameters are said beside the device, never its identifiers.
        let wipe = try #require(rows.first { $0.event == "DEVICE_ACTION_EVENT" })
        #expect(wipe.details == ["iPhone or iPad (iPhone 16)", "ACTION_EXECUTION_STATUS: ACTION_SUCCESS", "ACTION_TYPE: ACCOUNT_WIPE"])
    }
}
