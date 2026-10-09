import Darwin
import Foundation
import Testing
@testable import Vault

/// The guided setup's folder: made private, recognised by identity, and wiped of exactly the files whose
/// bytes were read (GamGUI's `_is_managed` and `_wipe_file`, with the incidents behind them).
@Suite("Setup folder")
struct SetupFolderTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-setup-\(UUID().uuidString)")

    private func put(_ name: String, in folder: URL, _ text: String? = nil) throws {
        let fallback = name == "oauth2service.json"
            ? #"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com"}"#
            : #"{"placeholder": true}"#
        try Data((text ?? fallback).utf8).write(to: folder.appending(path: name))
    }

    private func names(_ folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    @Test func prepareMakesAPrivateFolderOfThisUsers() throws {
        let folder = try SetupFolder.prepare(url)
        var info = stat()
        #expect(lstat(folder.url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(info.st_uid == getuid())
        chmod(url.path, 0o755)
        _ = try SetupFolder.prepare(url)
        #expect(lstat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "a loosened mode is tightened again")
    }

    @Test func aLinkInItsPlaceIsRefused() throws {
        let real = FileManager.default.temporaryDirectory.appending(path: "elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)
        #expect(throws: SetupFolder.Failure.unsafe(url.path)) { try SetupFolder.prepare(url) }
    }

    @Test func theWipeRemovesExactlyWhatWasReadAndLeavesTheRest() throws {
        let folder = try SetupFolder.prepare(url)
        for name in ["oauth2service.json", "oauth2.txt", "client_secrets.json", "gam.cfg"] { try put(name, in: url) }
        let staged = try folder.stage()
        #expect(Set(staged.found.keys) == Set(Credential.allCases))
        #expect(Set(staged.wipe()) == Set(Credential.allCases))
        #expect(try names(url) == ["gam.cfg"])
    }

    /// GamGUI failure: a staging folder swapped for a link made it wipe files it never imported. Here the
    /// folder is held open from the read, and a file replaced since is another inode: left alone.
    @Test func aFileReplacedAfterTheReadIsNotWiped() throws {
        let folder = try SetupFolder.prepare(url)
        try put("oauth2service.json", in: url)
        try put("oauth2.txt", in: url)
        let staged = try folder.stage()
        let swapped = url.appending(path: "oauth2.txt")
        try FileManager.default.removeItem(at: swapped)
        try put("oauth2.txt", in: url, #"{"someone": "else's"}"#)
        #expect(staged.wipe() == [.oauth2Service])
        #expect(try String(contentsOf: swapped, encoding: .utf8) == #"{"someone": "else's"}"#)
    }

    /// GamGUI failure: a case-variant spelling of its own folder compared unequal by name. Identity
    /// decides here, so a folder moved away and replaced at the same path is not ours.
    @Test func aFolderReplacedSincePrepareIsNotOurs() throws {
        let folder = try SetupFolder.prepare(url)
        let moved = FileManager.default.temporaryDirectory.appending(path: "moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try put("oauth2service.json", in: url)
        try put("oauth2.txt", in: url)
        #expect(throws: SetupFolder.Failure.replaced) { try folder.stage() }
        #expect(try names(url) == ["oauth2service.json", "oauth2.txt"])
    }

    @Test func droppingTheStagedReadWipesNothing() throws {
        let folder = try SetupFolder.prepare(url)
        try put("oauth2service.json", in: url)
        try put("oauth2.txt", in: url)
        _ = try folder.stage()
        #expect(try names(url) == ["oauth2service.json", "oauth2.txt"])
    }
}
