import Foundation
import FoundationModels

/// Plain English to a checked command (plan 2026-11-19, F5b; the D&D game's method, `~/dandd/game/docs/DM-MODEL.md`). The model
/// never writes GAM syntax. It narrows in small picks, each from a list made here at run time (a category, a subcategory when the
/// category is large, then a command), and copies the operator's words into that command's slots. Code checks every slot: a
/// choice is its own list; a person or a group is looked up in the cached directory, never invented; one re-ask names the
/// fault, then the slot is left empty. The caller builds the command through the Builder's own doors (`GamCommands.catalogRead`,
/// a curated command's `built`), and the Builder opens with it filled: a read runs on the operator's Run, a curated change goes
/// to its preview and confirm, and nothing runs from here (invariant 10). The model reads the operator's own sentence and the
/// catalog's plain words, never the directory or anything GAM printed. This module reaches no command
/// (`WriteRouteTests.theLogReaderCanRunNothing`): the caller hands it the commands as plain words (`Command`).
public enum CommandFinder {
    // MARK: what it picks from

    /// One field of a command, as plain words.
    public struct Slot: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// The person the command is about (GamGUI's target user: whose account, mail or files it reads or changes): their
            /// address, found in the directory from the words that name them.
            case owner
            /// Someone else in the directory, found the same way.
            case person
            /// A group in the directory, the same way.
            case group
            /// One email address: as typed, or someone or a group the directory finds.
            case address
            /// The words as they are.
            case text
            /// One of these, and nothing else.
            case choice([String])
        }

        public let key: String
        public let label: String
        public let kind: Kind
        public let required: Bool
        /// GAM's grammar word for it (`<CrOSDeviceID>`), said beside a text slot's label so an ID isn't taken for any word;
        /// anything else (a curated field's example query) is never shown, so the model isn't handed GAM's syntax to copy.
        public let hint: String

        public init(key: String, label: String, kind: Kind, required: Bool, hint: String = "") {
            self.key = key
            self.label = label
            self.kind = kind
            self.required = required
            self.hint = hint.hasPrefix("<") && hint.hasSuffix(">") && !hint.contains(" ") ? hint : ""
        }

        /// A field from GamGUI's slot kind (`CommandCatalog.Slot.Kind`, `CuratedCommand.Field.Kind`, by raw value), so the
        /// caller copies fields and decides nothing: `target_user` is the person it's about, `user` another person, `email` an
        /// address, `choice` its `choices`, anything else text.
        public init(key: String, label: String, gamKind: String, required: Bool, choices: [String] = [], hint: String = "") {
            let kind: Kind = switch gamKind {
            case "target_user": .owner
            case "user": .person
            case "group": .group
            case "email": .address
            case "choice": .choice(choices)
            default: .text
            }
            self.init(key: key, label: label, kind: kind, required: required, hint: hint)
        }
    }

    /// A command the finder may pick: one the Builder runs (a runnable catalog read) or one of GamGUI's curated commands, which
    /// are listed first.
    public struct Command: Sendable, Hashable, Identifiable {
        public let id: String
        public let category: String
        public let subcategory: String
        /// What it does in plain words: its label in a pick (a catalog command's gloss, a curated one's name).
        public let words: String
        public let curated: Bool
        /// A curated change (previewed and confirmed in the Builder): offered only for a request to change something.
        public let changes: Bool
        public let slots: [Slot]

        public init(id: String, category: String, subcategory: String, words: String, curated: Bool, changes: Bool, slots: [Slot]) {
            self.id = id
            self.category = category
            self.subcategory = subcategory
            self.words = words
            self.curated = curated
            self.changes = changes
            self.slots = slots
        }
    }

    /// Someone or a group in the cached directory: the address, and the other addresses and names it's known by.
    public struct Known: Sendable, Hashable {
        public let address: String
        public let names: [String]

        public init(address: String, names: [String]) {
            self.address = address
            self.names = names
        }
    }

    /// The cached directory, as far as it has been read: nil when it hasn't been.
    public struct Directory: Sendable {
        public let people: [Known]?
        public let groups: [Known]?

        public init(people: [Known]?, groups: [Known]?) {
            self.people = people
            self.groups = groups
        }
    }

    // MARK: what it finds

    /// A slot code left empty or filled with a doubt, in words for the screen (never for the model).
    public struct Note: Sendable, Hashable {
        public let slot: String
        public let text: String
    }

    /// One pick the narrowing made: a listed label, or none.
    public struct Option: Sendable, Hashable {
        public let label: String
        /// Every command the label stands for, in the list's order: a catalog's same words for alike commands (`print users` and
        /// `print users select …`) are one choice, and the slots decide among them.
        public let commands: [Command]
    }

    /// The command found, with its checked values, or none; and the other command when the samples split, to ask which.
    public struct Finding: Sendable, Equatable {
        /// The command's id, or nil when nothing listed does what was asked.
        public let command: String?
        /// The command's checked values, by slot key: each the operator's own words, or an address the directory found from them.
        public let values: [String: String]
        public let notes: [Note]
        /// The other command a sample picked, when the three samples split: the screen asks which of the two was meant.
        public let alternative: Option?
        /// The picks, in order (category, subcategory, command), for the eval and for the screen's "how it got here".
        public let picks: [String]
        public let chosen: Option?
    }

    // MARK: the model

    /// Asks a model for one guided answer, each in a fresh session: the on-device model, or a stand-in in tests.
    public protocol Asking: Sendable {
        /// `sample` nil is greedy (the same answer for the same words); a number is a seeded sample, for the ambiguity check.
        func answer(instructions: String, prompt: String, schema: GenerationSchema, sample: Int?) async throws -> GeneratedContent
    }

    /// The system's on-device model: greedy, or a seeded sample at a modest temperature; capped, as every answer here is short.
    public struct OnDevice: Asking {
        public init() {}

        public func answer(instructions: String, prompt: String, schema: GenerationSchema, sample: Int?) async throws -> GeneratedContent {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let options = sample.map { GenerationOptions(samplingMode: .random(top: 8, seed: UInt64($0)), temperature: 0.7, maximumResponseTokens: 250) }
                ?? GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 250)
            return try await session.respond(to: prompt, schema: schema, options: options).content
        }
    }

    /// Whether the on-device model can answer now, and if not, why, in words.
    public static var unavailable: String? { OnDeviceModel.unavailable("plain English turned into a command") }

    // MARK: the menu

    /// The longest list one pick is given: past about 40 choices, picks get worse (the D&D game's `menuCap`).
    static let cap = 40
    /// The pick that says nothing listed fits.
    static let none = "none"
    /// The longest request read: a sentence, not a document.
    static let longest = 300

    /// The commands as the picks list them. A request to change something picks among the curated changes alone. A request to
    /// see something narrows the reads: a category (the most commands first), a subcategory when the category has more than
    /// `cap` choices, then a command, curated ones first in each list, then the catalog's in its order, alike words one choice.
    public struct Menu: Sendable {
        public let commands: [Command]

        public init(_ commands: [Command]) { self.commands = commands }

        /// GamGUI's curated changes, for a request to change something.
        var changes: [Option] { Self.options(commands.filter(\.changes)) }

        /// Every command that only reads: the catalog's and GamGUI's curated reads.
        var reads: [Command] { commands.filter { !$0.changes } }

        /// Each category of the reads, the most commands first (Users leads), then by name.
        var categories: [String] {
            let counts = Dictionary(grouping: reads, by: \.category).mapValues(\.count)
            return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
        }

        func commands(in category: String) -> [Command] { reads.filter { $0.category == category } }

        /// A line for each category the reads are narrowed by subcategory in, naming them: "Users holds: Calendars, Drive, …".
        /// The category's bare name doesn't say a person's signature or Drive files are in it (asked for them, the category
        /// pick said none).
        var holds: [String] {
            categories.filter(needsSubcategory).map { "\($0) holds: " + subcategories(of: $0).joined(separator: ", ") + "." }
        }

        /// A subcategory's label: its name, or the category's for the commands in none.
        static func label(_ command: Command) -> String { command.subcategory.isEmpty ? command.category : command.subcategory }

        /// A category's subcategory labels, in the order its commands first name them (curated first).
        func subcategories(of category: String) -> [String] {
            var seen: Set<String> = []
            return Self.ordered(commands(in: category)).map(Self.label).filter { seen.insert($0).inserted }
        }

        /// Curated first, then the catalog's, each in its own order.
        static func ordered(_ commands: [Command]) -> [Command] { commands.filter(\.curated) + commands.filter { !$0.curated } }

        /// The choices a list of commands makes: one per distinct words, curated first.
        static func options(_ commands: [Command]) -> [Option] {
            var options: [Option] = [], at: [String: Int] = [:]
            for command in ordered(commands) {
                if let index = at[command.words] {
                    options[index] = Option(label: command.words, commands: options[index].commands + [command])
                } else {
                    at[command.words] = options.count
                    options.append(Option(label: command.words, commands: [command]))
                }
            }
            return options
        }

        /// What the command pick lists for `category`, after its subcategory pick when it needs one (`needsSubcategory`).
        func options(in category: String, subcategory: String?) -> [Option] {
            Self.options(commands(in: category).filter { subcategory == nil || Self.label($0) == subcategory })
        }

        func needsSubcategory(_ category: String) -> Bool { Self.options(commands(in: category)).count > cap }

        /// The longest list a pick after the category's is given: every one is within `cap` (`CommandFinderTests` holds the
        /// vendored catalog to it). The categories are the catalog's own, about 50 short names (the plan's ~200 tokens).
        public var longestList: Int {
            categories.flatMap { category in
                needsSubcategory(category)
                    ? [subcategories(of: category).count] + subcategories(of: category).map { options(in: category, subcategory: $0).count }
                    : [options(in: category, subcategory: nil).count]
            }.max() ?? 0
        }
    }

    // MARK: finding

    /// The command `sentence` asks for, narrowed in picks, its slots filled from the sentence and checked against `directory`.
    public static func find(_ sentence: String, in menu: Menu, directory: Directory, using model: some Asking) async throws -> Finding {
        let request = Self.request(sentence)
        let narrowed = try await narrow(request, in: menu, using: model)
        guard let chosen = narrowed.chosen else {
            return Finding(command: nil, values: [:], notes: [], alternative: nil, picks: narrowed.picks, chosen: nil)
        }
        let filled = try await fill(request, chosen, directory: directory, using: model)
        return Finding(command: filled.command, values: filled.values, notes: filled.notes, alternative: narrowed.alternative,
                       picks: narrowed.picks, chosen: chosen)
    }

    /// The operator's sentence as the model reads it: trimmed, one line, at most `longest` characters.
    static func request(_ sentence: String) -> String {
        String(sentence.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(longest))
    }

    /// What the narrowing picked: the labels in order, the option chosen (nil for none), and another a sample picked.
    public struct Narrowed: Sendable, Equatable {
        public let picks: [String]
        public let chosen: Option?
        public let alternative: Option?
    }

    /// What the request asks for first, to see or to change something: a change is picked among the curated changes alone, so a
    /// question never drafts one (a pick almost never says none: offered the curated commands first, "Is bob suspended?" picked
    /// Suspend account). Then a read narrows by category, a subcategory when the category is large, then a command. Each is a
    /// greedy pick in a fresh session; the pick that names the command is asked twice more, sampled, and another command a
    /// sample picks is the alternative to ask about.
    public static func narrow(_ request: String, in menu: Menu, using model: some Asking) async throws -> Narrowed {
        guard let asks = try await pick(request, from: Intent.allCases.map(\.rawValue), step: .intent, using: model).flatMap(Intent.init) else {
            return Narrowed(picks: [none], chosen: nil, alternative: nil)
        }
        if asks == .change {
            let changes = menu.changes
            guard let label = try await pick(request, from: changes.map(\.label), step: .command, using: model) else {
                return Narrowed(picks: [asks.rawValue, none], chosen: nil, alternative: nil)
            }
            return try await sampled(request, label, among: changes, picks: [asks.rawValue, label], using: model)
        }
        guard let category = try await pick(request, from: menu.categories, step: .category, holds: menu.holds, using: model) else {
            return Narrowed(picks: [asks.rawValue, none], chosen: nil, alternative: nil)
        }
        var picks = [asks.rawValue, category], subcategory: String?
        if menu.needsSubcategory(category) {
            guard let sub = try await pick(request, from: menu.subcategories(of: category), step: .subcategory, using: model) else {
                return Narrowed(picks: picks + [none], chosen: nil, alternative: nil)
            }
            picks.append(sub)
            subcategory = sub
        }
        let options = menu.options(in: category, subcategory: subcategory)
        let labels = options.map(\.label)
        guard let label = try await pick(request, from: labels, step: .command, using: model) else {
            return Narrowed(picks: picks + [none], chosen: nil, alternative: nil)
        }
        return try await sampled(request, label, among: options, picks: picks + [label], using: model)
    }

    /// The greedy pick `label` among `options`, checked against two seeded samples of the same pick: another label a sample picks
    /// is the alternative (the commoner, when they differ). A sample that fails (a guardrail stop, say) or picks none casts no vote.
    static func sampled(_ request: String, _ label: String, among options: [Option], picks: [String], using model: some Asking) async throws -> Narrowed {
        var votes: [String] = []
        for sample in 1...2 {
            try Task.checkCancellation()
            if let vote = try? await pick(request, from: options.map(\.label), step: .command, sample: sample, using: model), vote != label {
                votes.append(vote)
            }
        }
        try Task.checkCancellation()
        let other = votes.max { a, b in votes.count(of: a) < votes.count(of: b) }
        return Narrowed(picks: picks, chosen: options.first { $0.label == label },
                        alternative: other.flatMap { other in options.first { $0.label == other } })
    }

    /// What a request asks for: the first pick's labels.
    public enum Intent: String, CaseIterable, Sendable {
        case see = "See or list something"
        case change = "Change something"
    }

    enum Step {
        case intent, category, subcategory, command

        /// The last line of the prompt: what this pick is for.
        var task: String {
            switch self {
            case .intent: "Pick what the request asks for."
            case .category: "Pick the part of Google Workspace the request is about."
            case .subcategory: "Pick the kind of thing the request is about."
            case .command: "Pick what the request asks to do."
            }
        }
    }

    /// The standing instructions of every pick: no example sentences (the model copies them), labels only.
    static let pickInstructions = """
        You help an IT administrator find a Google Workspace admin command. Read the administrator's request and pick the \
        listed choice that matches it. Pick only a listed choice. If no listed choice matches the request, pick none.
        """

    /// The pick's answer: a few words on what was asked, written first so the pick follows from it, then the pick.
    static let asks = (name: "asks", description: "What the request asks for, in a few words")

    /// A guided pick of one of `labels` or none, greedy unless `sample`: nil for none, or for an answer that didn't read the
    /// request (its first field empty or the field's own description echoed back, as the D&D chooser found). The see-or-change
    /// pick offers no none: every request is one or the other, and offered none it said none for two plain questions of 22.
    /// `holds` is a line after the list, from the catalog: what each large category holds.
    static func pick(_ request: String, from labels: [String], step: Step, holds: [String] = [], sample: Int? = nil,
                     using model: some Asking) async throws -> String? {
        let choices = step == .intent ? labels : labels + [none]
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Pick", properties: [
            .init(name: asks.name, description: asks.description, schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "pick", description: step == .intent ? "One of the listed choices" : "One of the listed choices, or none",
                  schema: DynamicGenerationSchema(name: "Choice", anyOf: choices)),
        ]), dependencies: [])
        let prompt = "Choices:\n" + labels.map { "- \($0)" }.joined(separator: "\n") + "\n\n" + holds.map { "\($0)\n\n" }.joined()
            + "Request: \u{201C}\(request)\u{201D}\n\n" + step.task
        try Task.checkCancellation()
        let content = try await model.answer(instructions: pickInstructions, prompt: prompt, schema: schema, sample: sample)
        guard read(content), let picked = try? content.value(String.self, forProperty: "pick"), labels.contains(picked) else { return nil }
        return picked
    }

    /// Whether an answer read the request: its first field holds words, not nothing and not its own description.
    static func read(_ content: GeneratedContent) -> Bool {
        let said = ((try? content.value(String.self, forProperty: asks.name)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !said.isEmpty && said.lowercased() != asks.description.lowercased()
    }

    // MARK: filling

    /// A command's values, checked, and what code noted about them.
    public struct Filled: Sendable, Equatable {
        public let command: String
        public let values: [String: String]
        public let notes: [Note]
    }

    /// `option`'s slots filled from `request`: asked of the command with the most slots, each value checked (`check`), one
    /// re-ask naming the faults, then a faulty slot left empty and noted. Then the command of `option` the values suit best:
    /// every required slot filled, the most of its slots used, the fewest left over, the list's order.
    public static func fill(_ sentence: String, _ option: Option, directory: Directory, using model: some Asking) async throws -> Filled {
        let request = Self.request(sentence)
        guard let widest = option.commands.max(by: { $0.slots.count < $1.slots.count }) else {
            return Filled(command: "", values: [:], notes: [])
        }
        var byLabel: [String: String] = [:], notes: [Note] = []
        if !widest.slots.isEmpty {
            let names = fieldNames(widest.slots)
            let schema = try fillSchema(widest.slots, names: names)
            try Task.checkCancellation()
            let first = try await model.answer(instructions: fillInstructions, prompt: fillPrompt(request, option.label, widest.slots, names: names),
                                               schema: schema, sample: nil)
            var faults: [(slot: Slot, value: String, fault: String)] = []
            for (slot, name) in zip(widest.slots, names) {
                switch check(value(first, name), slot, request: request, directory: directory) {
                case .empty: break
                case .value(let value, let note):
                    byLabel[slot.label] = value
                    if let note { notes.append(Note(slot: slot.label, text: note)) }
                case .unsure(let note): notes.append(Note(slot: slot.label, text: note))
                case .fault(let raw, let fault): faults.append((slot, raw, fault))
                }
            }
            if !faults.isEmpty {
                // One re-ask, naming each fault in the request's own words; then a slot still at fault is left empty.
                try Task.checkCancellation()
                let again = try? await model.answer(instructions: fillInstructions,
                                                    prompt: fillPrompt(request, option.label, widest.slots, names: names, faults: faults),
                                                    schema: schema, sample: nil)
                try Task.checkCancellation()
                for fault in faults {
                    let name = names[widest.slots.firstIndex(of: fault.slot)!]
                    switch again.map({ check(value($0, name), fault.slot, request: request, directory: directory) }) ?? .fault(fault.value, fault.fault) {
                    case .value(let value, let note):
                        byLabel[fault.slot.label] = value
                        if let note { notes.append(Note(slot: fault.slot.label, text: note)) }
                    case .unsure(let note): notes.append(Note(slot: fault.slot.label, text: note))
                    case .empty: notes.append(Note(slot: fault.slot.label, text: "Left empty: " + fault.fault + "."))
                    case .fault(_, let still): notes.append(Note(slot: fault.slot.label, text: "Left empty: " + still + "."))
                    }
                }
            }
        }
        // The command of the option the values suit: each candidate's slots by label.
        let best = option.commands.enumerated().max { a, b in
            score(a.element, byLabel, a.offset).lexicographicallyPrecedes(score(b.element, byLabel, b.offset))
        }!.element
        var values: [String: String] = [:]
        for slot in best.slots { if let value = byLabel[slot.label] { values[slot.key] = value } }
        let kept = Set(best.slots.map(\.label))
        return Filled(command: best.id, values: values, notes: notes.filter { kept.contains($0.slot) })
    }

    /// How well `values` suit `command` (higher is better): every required slot filled, then the most of its slots filled,
    /// then the fewest slots, then earlier in the list.
    static func score(_ command: Command, _ values: [String: String], _ position: Int) -> [Int] {
        let filled = command.slots.filter { values[$0.label] != nil }.count
        let ready = command.slots.allSatisfy { !$0.required || values[$0.label] != nil }
        return [ready ? 1 : 0, filled, -command.slots.count, -position]
    }

    static let fillInstructions = """
        You copy words from an IT administrator's request into the fields of a Google Workspace admin command. Copy each value \
        exactly as the request writes it, and only from the request. Leave a field empty when the request doesn't say it. \
        Never make up a name, an address or an ID, and never write a command.
        """

    /// A field's name in the answer: its label in lowercase words joined by underscores, numbered when two match.
    static func fieldNames(_ slots: [Slot]) -> [String] {
        var used: [String: Int] = [:]
        return slots.map { slot in
            let base = slot.label.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "_")
            let name = base.isEmpty ? "field" : base
            used[name, default: 0] += 1
            return used[name] == 1 ? name : "\(name)_\(used[name]!)"
        }
    }

    /// The text a field's empty or unsaid answer is: a choice has it among its values.
    static let unsaid = "not said"

    static func fillSchema(_ slots: [Slot], names: [String]) throws -> GenerationSchema {
        let text = DynamicGenerationSchema(type: String.self)
        var properties: [DynamicGenerationSchema.Property] = [.init(name: asks.name, description: asks.description, schema: text)]
        for (slot, name) in zip(slots, names) {
            let schema: DynamicGenerationSchema, about: String
            switch slot.kind {
            case .owner: (schema, about) = (text, "\(slot.label): the person whose account, mail or files this is about, as the request names them, or empty")
            case .person: (schema, about) = (text, "\(slot.label): a person, as the request names them, or empty")
            case .group: (schema, about) = (text, "\(slot.label): the group, as the request names it, or empty")
            case .address: (schema, about) = (text, "\(slot.label): an email address or a person, as the request writes it, or empty")
            case .text: (schema, about) = (text, "\(slot.label)" + (slot.hint.isEmpty ? "" : " (\(slot.hint))") + ", copied from the request, or empty")
            case .choice(let choices):
                (schema, about) = (DynamicGenerationSchema(name: "\(name)_choice", anyOf: choices + [unsaid]), "\(slot.label), as the request says it")
            }
            properties.append(.init(name: name, description: about, schema: schema))
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Fields", properties: properties), dependencies: [])
    }

    /// The fill's prompt: the command's words, the request, and after a first answer, each fault it had.
    static func fillPrompt(_ request: String, _ words: String, _ slots: [Slot], names: [String],
                           faults: [(slot: Slot, value: String, fault: String)] = []) -> String {
        var lines = ["Command: \(words)", "Request: \u{201C}\(request)\u{201D}"]
        if !faults.isEmpty {
            lines.append("Your last answer had these faults:")
            lines += faults.map { "- \(names[slots.firstIndex(of: $0.slot)!]): \($0.fault)." }
            lines.append("Answer again. Copy each value from the request's own words, or leave the field empty.")
        } else {
            lines.append("Fill in the fields from the request.")
        }
        return lines.joined(separator: "\n")
    }

    static func value(_ content: GeneratedContent, _ name: String) -> String {
        ((try? content.value(String.self, forProperty: name)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: checking

    /// A value checked: none; one to keep (with a doubt for the screen); one code can't settle, left empty with a note for the
    /// screen (never told to the model: it names the directory's people); or a fault the model is told of once, in the
    /// request's own words.
    enum Checked: Equatable {
        case empty
        case value(String, note: String?)
        case unsure(String)
        case fault(String, String)
    }

    /// `raw`, from the model, checked for `slot`: every value must be the request's own words, whole words, and is kept as the
    /// request writes them; a choice must be one of its own too (a role the request didn't say is left at the field's default:
    /// given "put alice in the sales group", the model picked member, and the same pick could have been owner); a person or a
    /// group must be one the directory finds by them (an address typed in full is kept, with a doubt when the directory doesn't
    /// hold it); an address must be one, or someone or a group the directory finds.
    static func check(_ raw: String, _ slot: Slot, request: String, directory: Directory) -> Checked {
        let said = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}.,;:?!")))
        if said.isEmpty || said.lowercased() == unsaid { return .empty }
        if case .choice(let choices) = slot.kind {
            guard choices.contains(said) else { return .fault(said, "\u{201C}\(said)\u{201D} isn't one of " + choices.joined(separator: ", ")) }
            return span(said, in: request) != nil ? .value(said, note: nil)
                : .fault(said, "\u{201C}\(said)\u{201D} isn't in the request, so \(slot.label) keeps its default")
        }
        // Someone's or a group's name may close with a possessive ("carol's" is carol); any other words are kept whole
        // ("Children's").
        let named = if case .text = slot.kind { said } else { possessive(said) }
        guard let words = span(named, in: request) ?? (named == said ? nil : span(said, in: request)) else {
            return .fault(said, "\u{201C}\(said)\u{201D} isn't in the request")
        }
        switch slot.kind {
        case .text, .choice: return .value(words, note: nil)
        case .owner, .person: return lookUp(words, in: directory.people, what: "anyone", read: "Users")
        case .group:
            // "the IT group" is the group IT: the kind's own word and an article aren't its name, when the whole isn't one.
            let found = lookUp(words, in: directory.groups, what: "a group", read: "Groups")
            let bare = bareGroup(words)
            guard case .fault = found, bare != words, !bare.isEmpty else { return found }
            if case .fault = lookUp(bare, in: directory.groups, what: "a group", read: "Groups") { return found }
            return lookUp(bare, in: directory.groups, what: "a group", read: "Groups")
        case .address:
            if isAddress(words) { return .value(words.lowercased(), note: nil) }
            let found = [lookUp(words, in: directory.people, what: "anyone", read: "Users"), lookUp(words, in: directory.groups, what: "a group", read: "Groups")]
            if let one = found.first(where: { if case .value = $0 { true } else { false } }) { return one }
            if let unsure = found.first(where: { if case .unsure = $0 { true } else { false } }) { return unsure }
            return .fault(words, "\u{201C}\(words)\u{201D} isn't an email address or anyone in the directory")
        }
    }

    /// `words` without a leading "the" or a closing "group".
    static func bareGroup(_ words: String) -> String {
        var bare = words
        if bare.lowercased().hasPrefix("the ") { bare = String(bare.dropFirst(4)) }
        if bare.lowercased().hasSuffix(" group") { bare = String(bare.dropLast(6)) }
        return bare.trimmingCharacters(in: .whitespaces)
    }

    /// `words` without a closing possessive ("carol's" is carol).
    static func possessive(_ words: String) -> String {
        let plain = words.replacingOccurrences(of: "\u{2019}", with: "'")
        return plain.lowercased().hasSuffix("'s") && plain.count > 2 ? String(plain.dropLast(2)) : plain
    }

    /// Where `words` stand in `request` as whole words: the request's own text there, as it writes it, or nil. Case, curly
    /// apostrophes and runs of white space aside. Part of a longer word or an address is no match: "Carol" isn't in "Reset
    /// Caroline's password", "manager" isn't in "the managers group", "delete" isn't in "is deleted", "bob" isn't in
    /// "bob@gmail.com" (review 2026-11-21: each was taken before). A possessive after the words is a boundary ("carol's").
    static func span(_ words: String, in request: String) -> String? {
        func plain(_ character: Character) -> Character {
            if character == "\u{2019}" { return "'" }
            let lower = String(character).lowercased()
            return lower.count == 1 ? Character(lower) : character
        }
        // The request's characters, each with where it stands, a run of white space as one space.
        var text: [(character: Character, at: String.Index)] = []
        var index = request.startIndex
        while index < request.endIndex {
            let character = request[index]
            if !character.isWhitespace { text.append((plain(character), index)) } else if text.last?.character != " " { text.append((" ", index)) }
            index = request.index(after: index)
        }
        let needle = Array(words.split(whereSeparator: \.isWhitespace).joined(separator: " ").map(plain))
        guard !needle.isEmpty, needle.count <= text.count else { return nil }
        // Whether the character at `at` carries a word on past the match, `beyond` being the one after it, away from the match.
        func continues(_ at: Int, beyond: Int) -> Bool {
            guard text.indices.contains(at) else { return false }
            let character = text[at].character
            if character.isLetter || character.isNumber || character == "@" || character == "_" { return true }
            guard character == "." || character == "-", text.indices.contains(beyond) else { return false }
            return text[beyond].character.isLetter || text[beyond].character.isNumber
        }
        for start in 0...(text.count - needle.count) {
            let end = start + needle.count
            guard text[start..<end].map(\.character) == needle, !continues(start - 1, beyond: start - 2), !continues(end, beyond: end + 1) else {
                continue
            }
            return String(request[text[start].at..<request.index(after: text[end - 1].at)])
        }
        return nil
    }

    /// One address: a name, an `@`, and a domain with a dot, nothing else.
    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return !text.contains { $0.isWhitespace || "<>,;()\"".contains($0) }
    }

    /// `words` looked up in `known`: by address (or another address it has), then by the address's own name ("carol" for
    /// carol@example.com), then by a name it's known by. One found is its address; more than one is left for the operator; none
    /// is a fault, but an address typed in full is kept with a doubt. Without the directory read, only an address typed in full
    /// is kept.
    static func lookUp(_ words: String, in known: [Known]?, what: String, read: String) -> Checked {
        let wanted = words.lowercased()
        guard let known else {
            return isAddress(words) ? .value(wanted, note: "The directory isn't read yet, so this address isn't checked: open \(read) to read it.")
                : .unsure("Left empty: the directory isn't read yet, so \u{201C}\(words)\u{201D} can't be found. Open \(read), or type the address.")
        }
        let tiers: [(Known) -> Bool] = [
            { $0.address.lowercased() == wanted || $0.names.contains { $0.contains("@") && $0.lowercased() == wanted } },
            { $0.address.lowercased().split(separator: "@").first.map(String.init) == wanted },
            { $0.names.contains { !$0.contains("@") && $0.lowercased() == wanted } },
        ]
        for tier in tiers {
            let found = known.filter(tier)
            if found.count == 1 { return .value(found[0].address, note: nil) }
            if found.count > 1 {
                let shown = found.prefix(5).map(\.address).joined(separator: ", ")
                return .unsure("Left empty: \u{201C}\(words)\u{201D} could be \(shown)\(found.count > 5 ? " or more" : ""). Pick one.")
            }
        }
        if isAddress(words) { return .value(wanted, note: "\(wanted) isn't in the directory as last read: check it before you run this.") }
        return .fault(words, "\u{201C}\(words)\u{201D} isn't \(what) in the directory")
    }
}

private extension Array where Element: Equatable {
    func count(of element: Element) -> Int { filter { $0 == element }.count }
}
