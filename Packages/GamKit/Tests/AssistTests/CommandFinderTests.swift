import Foundation
import FoundationModels
import GamEngine
import Testing
@testable import Assist

/// Plain English to a checked command (plan F5b), with a stand-in model: the lists each pick is given, the checks on every slot,
/// the one re-ask, the split samples, and that the model reads only the operator's sentence. The real model's measurement is
/// `CommandFinderEvals` (on demand).
@Suite("Command finder")
struct CommandFinderTests {
    /// A model whose answers are scripted by the prompt's task line and the sample, recording each prompt it reads.
    final class Scripted: CommandFinder.Asking, @unchecked Sendable {
        let lock = NSLock()
        var prompts: [String] = []
        let answers: @Sendable (_ prompt: String, _ sample: Int?) -> String

        init(_ answers: @escaping @Sendable (_ prompt: String, _ sample: Int?) -> String) { self.answers = answers }

        func answer(instructions: String, prompt: String, schema: GenerationSchema, sample: Int?) async throws -> GeneratedContent {
            lock.withLock { prompts.append(instructions + "\n" + prompt) }
            return try GeneratedContent(json: answers(prompt, sample))
        }

        var all: [String] { lock.withLock { prompts } }
    }

    static func pick(_ label: String) -> String { #"{"asks": "it asks for something", "pick": "\#(label)"}"# }

    /// A model that narrows to `category`, `subcategory` and `command` and fills with `fields` (JSON members).
    static func model(_ category: String, _ subcategory: String? = nil, _ command: String, fields: String = "",
                      samples: [Int: String] = [:], asks: CommandFinder.Intent = .see) -> Scripted {
        Scripted { prompt, sample in
            if prompt.hasPrefix("Command: ") { return #"{"asks": "it asks for something""# + (fields.isEmpty ? "" : ", " + fields) + "}" }
            if prompt.hasSuffix(CommandFinder.Step.intent.task) { return pick(asks.rawValue) }
            if prompt.hasSuffix(CommandFinder.Step.category.task) { return pick(category) }
            if prompt.hasSuffix(CommandFinder.Step.subcategory.task) { return pick(subcategory ?? "none") }
            // The command pick, among the changes or a read's list: the command when it's listed, else none.
            let wanted = sample.flatMap { samples[$0] } ?? command
            return pick(prompt.contains("- \(wanted)\n") ? wanted : "none")
        }
    }

    static let menu = FinderMenu.menu, directory = FinderMenu.directory

    // MARK: the lists

    /// A change is picked among GamGUI's curated changes alone; a read narrows the reads, every list after the categories at
    /// most 40 choices (the D&D game's cap), the one big category, Users, listed first and narrowed by its subcategories, and
    /// GamGUI's curated reads lead their lists.
    @Test func changesStandApartAndEveryListIsSmall() throws {
        #expect(Self.menu.changes.map(\.label) == CuratedCommand.all.filter { !$0.reads }.map(\.name))
        #expect(Self.menu.reads.allSatisfy { !$0.changes })
        #expect(Self.menu.longestList <= CommandFinder.cap, "\(Self.menu.longestList)")
        #expect(Self.menu.needsSubcategory("Users") && !Self.menu.needsSubcategory("Groups"))
        #expect(Self.menu.categories.first == "Users" && Self.menu.categories.count < 60, "\(Self.menu.categories)")
        let delegates = Self.menu.options(in: "Users", subcategory: "Gmail - Delegates").map(\.label)
        #expect(delegates.first == "List mailbox delegates" && delegates.contains("List a user's Gmail delegates."), "\(delegates)")
        // Every command the Builder runs is on the menu, and nothing else: the runnable reads and the curated commands.
        #expect(Self.menu.commands.count == FinderMenu.catalog.commands.filter(\.runnable).count + CuratedCommand.all.count)
    }

    /// Alike words are one choice, and the values decide which of the alike commands: "List users." with no one named is the
    /// whole list; with someone named, a command that takes them.
    @Test func theValuesPickAmongAlikeCommands() async throws {
        let option = try #require(Self.menu.options(in: "Users", subcategory: "Users").first { $0.label == "List users." })
        #expect(option.commands.count > 1)
        let everyone = try await CommandFinder.fill("list our users", option, directory: Self.directory,
                                                    using: Self.model("Users", "Users", "List users.", fields: #""user": """#))
        #expect(everyone.command == "raw.6078" && everyone.values.isEmpty)
        let one = try await CommandFinder.fill("list carol in users", option, directory: Self.directory,
                                               using: Self.model("Users", "Users", "List users.", fields: #""user": "carol""#))
        let command = try #require(option.commands.first { $0.id == one.command })
        #expect(command.slots.map(\.label) == ["User"] && one.values == [command.slots[0].key: "carol@example.com"])
    }

    // MARK: the checks

    static func check(_ raw: String, _ kind: CommandFinder.Slot.Kind, _ request: String,
                      directory: CommandFinder.Directory = directory) -> CommandFinder.Checked {
        CommandFinder.check(raw, CommandFinder.Slot(key: "a0", label: "User", kind: kind, required: true), request: request, directory: directory)
    }

    /// A slot holds the operator's own words, or the address the directory finds from them: by address or alias, the
    /// address's own name, then a name. Never words the request doesn't hold (GAM's query syntax the model knows, say).
    @Test func aSlotIsTheOperatorsWordsOrWhomTheyName() {
        #expect(Self.check("carol's", .person, "show carol's signature") == .value("carol@example.com", note: nil))
        #expect(Self.check("Carol Clark", .person, "show Carol Clark's signature") == .value("carol@example.com", note: nil))
        #expect(Self.check("a.anders@example.com", .person, "info on a.anders@example.com") == .value("alice@example.com", note: nil))
        #expect(Self.check("sales", .group, "who is in sales") == .value("sales@example.com", note: nil))
        #expect(Self.check("IT", .group, "list the IT group") == .value("it@example.com", note: nil), "groups only, not IT Admin")
        #expect(Self.check("dana", .address, "give dana access") == .value("dana@example.com", note: nil))
        #expect(Self.check("Bob@Gmail.com", .address, "forward to Bob@Gmail.com") == .value("bob@gmail.com", note: nil))
        #expect(Self.check("manager", .choice(["member", "manager", "owner"]), "make bob a manager") == .value("manager", note: nil))
        #expect(Self.check("not said", .choice(["member"]), "add bob") == .empty)
        // A choice the request didn't say: asked again, then the field's default.
        #expect(Self.check("owner", .choice(["member", "manager", "owner"]), "put alice in the sales group")
                == .fault("owner", "\u{201C}owner\u{201D} isn't in the request, so User keeps its default"))
        // Not the request's words: told to the model once.
        #expect(Self.check("isSuspended=true", .text, "find all suspended users")
                == .fault("isSuspended=true", "\u{201C}isSuspended=true\u{201D} isn't in the request"))
        #expect(Self.check("carol@example.com", .person, "show carol's signature")
                == .fault("carol@example.com", "\u{201C}carol@example.com\u{201D} isn't in the request"), "an address it worked out itself")
        #expect(Self.check("frank", .person, "show frank's account") == .fault("frank", "\u{201C}frank\u{201D} isn't anyone in the directory"))
        // Typed in full but not in the directory: kept, with a doubt.
        #expect(Self.check("frank@example.com", .person, "show frank@example.com")
                == .value("frank@example.com", note: "frank@example.com isn't in the directory as last read: check it before you run this."))
    }

    /// What code can't settle is left empty for the operator, never asked of the model (the note names the directory's people,
    /// which the model never reads): two people a name fits, or a directory not read yet.
    @Test func whatCodeCantSettleIsLeftForTheOperator() {
        let two = CommandFinder.Directory(people: [.init(address: "carol@example.com", names: ["Carol Clark", "Carol"]),
                                                   .init(address: "c.smith@example.com", names: ["Carol Smith", "Carol"])], groups: [])
        #expect(Self.check("Carol", .person, "show Carol's account", directory: two)
                == .value("carol@example.com", note: nil), "the address's own name comes first")
        #expect(Self.check("Carol", .person, "show Carol's account",
                           directory: .init(people: [.init(address: "cc@example.com", names: ["Carol"]), .init(address: "cs@example.com", names: ["Carol"])],
                                            groups: []))
                == .unsure("Left empty: \u{201C}Carol\u{201D} could be cc@example.com, cs@example.com. Pick one."))
        let unread = CommandFinder.Directory(people: nil, groups: nil)
        #expect(Self.check("carol", .person, "show carol", directory: unread)
                == .unsure("Left empty: the directory isn't read yet, so \u{201C}carol\u{201D} can't be found. Open Users, or type the address."))
        if case .value("carol@example.com", let note?) = Self.check("carol@example.com", .person, "show carol@example.com", directory: unread) {
            #expect(note.contains("isn't read yet"))
        } else {
            Issue.record("an address typed in full is kept")
        }
    }

    /// A slot at fault is asked again once, naming the fault in the request's own words; still at fault, it's left empty and
    /// noted. Two calls, never a third.
    @Test func aFaultIsAskedAgainOnceThenLeftEmpty() async throws {
        let option = try #require(Self.menu.options(in: "Users", subcategory: "Gmail - Send As/Signature/Vacation")
            .first { $0.label == "Show a user's Gmail signature." })
        let model = Self.model("", nil, "", fields: #""user": "gina""#)
        let filled = try await CommandFinder.fill("show gina's signature", option, directory: Self.directory, using: model)
        #expect(filled.values.isEmpty)
        #expect(filled.notes == [.init(slot: "User", text: "Left empty: \u{201C}gina\u{201D} isn't anyone in the directory.")])
        #expect(model.all.count == 2)
        #expect(model.all.last?.contains("- user: \u{201C}gina\u{201D} isn't anyone in the directory.") == true, "\(model.all.last ?? "")")
        // Fixed on the re-ask: kept.
        let fixed = Scripted { prompt, _ in
            #"{"asks": "a signature", "user": "\#(prompt.contains("faults") ? "carol" : "carol's signature")"}"#
        }
        let second = try await CommandFinder.fill("show carol's signature", option, directory: Self.directory, using: fixed)
        #expect(second.values.values.first == "carol@example.com" && second.notes.isEmpty)
    }

    // MARK: narrowing

    /// The whole way, as the Builder will be handed it: a category, Users' subcategory, the command, the slot; built through
    /// the Builder's own door (`GamCommands.catalogRead`), whose argv is held to GamGUI's and which still refuses `todrive`.
    @Test func aSentenceBecomesABuiltRead() async throws {
        let model = Self.model("Users", "Gmail - Send As/Signature/Vacation", "Show a user's Gmail signature.", fields: #""user": "carol""#)
        let found = try await CommandFinder.find("show carol's signature", in: Self.menu, directory: Self.directory, using: model)
        #expect(found.picks == ["See or list something", "Users", "Gmail - Send As/Signature/Vacation", "Show a user's Gmail signature."])
        #expect(found.alternative == nil && found.notes.isEmpty)
        let command = try #require(FinderMenu.catalog.commands.first { $0.id == found.command })
        #expect(try GamCommands.catalogRead(command, values: found.values).argv == ["user", "carol@example.com", "show", "signature"])
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.catalogRead(command, values: [command.slots[0].key: "todrive"]) }
    }

    /// The model reads the operator's sentence and the catalog's words, nothing else: not one address or name from the
    /// directory reaches a prompt, however the slots go (found, not found, asked again).
    @Test func theModelReadsOnlyTheSentence() async throws {
        let model = Self.model("Groups", nil, "Add member to group", fields: #""group": "sales team", "member": "bob", "role": "not said""#,
                               asks: .change)
        let found = try await CommandFinder.find("add bob to the sales team", in: Self.menu, directory: Self.directory, using: model)
        #expect(found.command == "build.add_group_member" && found.values == ["member": "bob@example.com"])
        let directory = (Self.directory.people ?? []) + (Self.directory.groups ?? [])
        // Every address, and every name of more than one word (a one-word name, "IT" or "Sales", is also the catalog's word).
        let held = directory.flatMap { [$0.address] + $0.names.filter { $0.contains(" ") } }
            .filter { !"add bob to the sales team".contains($0.lowercased()) }
        for prompt in model.all { #expect(!held.contains { prompt.contains($0) }, "\(prompt)") }
        #expect(model.all.count == 6, "see or change, the change and two samples, fill, re-ask: \(model.all.count)")
    }

    /// None is nothing found; so is an answer whose first field is empty or echoes its own description (it didn't read the
    /// request).
    @Test func noneOrAnUnreadAnswerFindsNothing() async throws {
        let none = try await CommandFinder.find("wipe gina's phone", in: Self.menu, directory: Self.directory,
                                                using: Self.model("none", nil, "", asks: .change))
        #expect(none.command == nil && none.picks == ["Change something", "none"])
        let echo = Scripted { _, _ in #"{"asks": "What the request asks for, in a few words", "pick": "Groups"}"# }
        #expect(try await CommandFinder.find("list groups", in: Self.menu, directory: Self.directory, using: echo).command == nil)
        let empty = Scripted { _, _ in #"{"asks": " ", "pick": "Groups"}"# }
        #expect(try await CommandFinder.find("list groups", in: Self.menu, directory: Self.directory, using: empty).command == nil)
    }

    /// The command pick is sampled twice more: when a sample picks another command, it's the alternative the screen asks about;
    /// when both agree with the greedy pick, there's none.
    @Test func aSplitNamesTheOtherCommand() async throws {
        let split = Self.model("Groups", nil, "Show details for a group.", fields: #""group": "sales""#, samples: [1: "List groups."])
        let asked = try await CommandFinder.find("show the sales group", in: Self.menu, directory: Self.directory, using: split)
        #expect(asked.command == "raw.4056" && asked.alternative?.label == "List groups.")
        let agreed = Self.model("Groups", nil, "Show details for a group.", fields: #""group": "sales""#)
        #expect(try await CommandFinder.find("show the sales group", in: Self.menu, directory: Self.directory, using: agreed).alternative == nil)
    }
}
