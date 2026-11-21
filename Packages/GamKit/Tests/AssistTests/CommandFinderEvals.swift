import Foundation
import FoundationModels
import GamEngine
import Testing
import TestSupport
@testable import Assist

/// The finder's samples (`Tests/Fixtures/finder`, the operator's kinds of request), and the Builder's own search on each: always
/// run, no model. The samples must name commands the Builder runs and slots those commands have, or every number is a lie.
@Suite("Command finder samples")
struct CommandFinderSampleTests {
    @Test func theSamplesNameWhatTheBuilderRuns() throws {
        let dev = FinderCase.load("dev"), heldOut = FinderCase.load("heldout")
        #expect(dev.count >= 20 && heldOut.count >= 10, "\(dev.count) + \(heldOut.count)")
        #expect(Set((dev + heldOut).map(\.id)).count == dev.count + heldOut.count)
        let menu = Dictionary(uniqueKeysWithValues: FinderMenu.menu.commands.map { ($0.id, $0) })
        for sample in dev + heldOut {
            let commands = try sample.accept.map { try #require(menu[$0], "\(sample.id): \($0) isn't on the menu") }
            let labels = Set(commands.flatMap { $0.slots.map(\.label) })
            for label in Array(sample.values.keys) + Array((sample.allow ?? [:]).keys) {
                #expect(labels.contains(label), "\(sample.id): no accepted command has \(label)")
            }
        }
    }

    /// The eval's no-invented-value check holds whole words, as the finder does (review 2026-11-21): a name inside a longer
    /// one, or a role inside a plural, is invented.
    @Test func anInventedValueIsCaught() {
        let reset = FinderCase(id: "r", kind: "", category: "", input: "Reset Caroline's password", accept: [], values: [:])
        #expect(reset.invented(["User": "carol@example.com"]) == ["carol@example.com"])
        let managers = FinderCase(id: "m", kind: "", category: "", input: "Add Bob to the managers group", accept: [], values: [:])
        #expect(managers.invented(["Role": "manager", "Member": "bob@example.com"]) == ["manager"])
        let shown = FinderCase(id: "s", kind: "", category: "", input: "Show Carol's signature", accept: [], values: [:])
        #expect(shown.invented(["User": "carol@example.com"]).isEmpty)
    }

    /// The Builder's search, as typed: what the operator has today, given the same sentences. Printed for the plan; the model's
    /// eval prints the same numbers beside the finder's.
    @Test func theBuildersSearchOnTheSamples() {
        for split in ["dev", "heldout"] {
            let samples = FinderCase.load(split)
            func share(_ hit: (FinderCase) -> Bool) -> String { "\(samples.filter(hit).count)/\(samples.count)" }
            print("SEARCH \(split): Builder first \(share { Self.first(BuilderSearch.ids($0.input), $0) }), top 3 \(share { Self.top3(BuilderSearch.ids($0.input), $0) }); "
                + "ranked first \(share { Self.first(BuilderSearch.ranked($0.input), $0) }), top 3 \(share { Self.top3(BuilderSearch.ranked($0.input), $0) })")
        }
    }

    /// A search's first result is right: a right command, or nothing listed when nothing fits.
    static func first(_ ids: [String], _ sample: FinderCase) -> Bool { sample.accept.isEmpty ? ids.isEmpty : ids.first.map(sample.accept.contains) == true }

    /// One of its first three is right, or nothing listed when nothing fits.
    static func top3(_ ids: [String], _ sample: FinderCase) -> Bool { sample.accept.isEmpty ? ids.isEmpty : ids.prefix(3).contains(where: sample.accept.contains) }
}

#if canImport(Evaluations)
import Evaluations

/// Apple's Evaluations of the finder on the real on-device model, on demand only (they call the model, so plain `swift test`
/// skips them): `SWIFTGAMGUI_MODEL=1 swift test --package-path Packages/GamKit --filter CommandFinderEvals`. The dev split prints
/// each case; the held-out split only its means, so no change is fitted to it. Each run is saved under
/// `Tests/Fixtures/finder/results`. The plan's rule (F5): the finder is kept only if it beats the Builder's search on the held-out
/// split.
enum ModelRuns {
    static let on = ProcessInfo.processInfo.environment["SWIFTGAMGUI_MODEL"] == "1" && SystemLanguageModel.default.availability == .available
    static func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
    static let results = Fixtures.directory.appending(path: "finder/results")
}

enum FinderEvalError: Error { case noCase }

struct FinderEvaluation: Evaluation {
    let split: String
    let right = Metric("Right command")
    let offered = Metric("Right or offered")
    let asked = Metric("Asked")
    let intent = Metric("Right see or change")
    let category = Metric("Right category")
    let slots = Metric("Right slots")
    let invented = Metric("Invented a value")
    let builds = Metric("Builds")
    let seconds = Metric("Seconds")
    let searchFirst = Metric("Search first")
    let searchTop3 = Metric("Search top 3")
    let rankedFirst = Metric("Ranked first")
    let rankedTop3 = Metric("Ranked top 3")

    var dataset: ArrayLoader<ModelSample<FinderCase>> { ArrayLoader(samples: FinderCase.load(split).map { ModelSample(prompt: $0.input, expected: $0) }) }

    func subject(from sample: ModelSample<FinderCase>) async throws -> ModelSubject<FinderCase> {
        guard var answer = sample.expected else { throw FinderEvalError.noCase }
        let start = ContinuousClock.now
        let found = try await CommandFinder.find(answer.input, in: FinderMenu.menu, directory: FinderMenu.directory, using: CommandFinder.OnDevice())
        answer.seconds = ModelRuns.seconds(ContinuousClock.now - start)
        answer.found = found.command
        answer.alternative = found.alternative?.commands.map(\.id)
        let slots = FinderMenu.menu.commands.first { $0.id == found.command }?.slots ?? []
        answer.filled = Dictionary(uniqueKeysWithValues: slots.compactMap { slot in found.values[slot.key].map { (slot.label, $0) } })
        answer.notes = found.notes.map { "\($0.slot): \($0.text)" }
        answer.picks = found.picks
        if split == "dev" {
            let mark = sample.expected!.rightly(found.command) ? (sample.expected!.rightSlots(answer.filled ?? [:]) ? "" : "  ✗ slots") : "  ✗ want \(sample.expected!.accept)"
            print("EVAL \(answer.id) \"\(answer.input)\" → \(found.picks.joined(separator: " › ")) [\(found.command ?? "none")] \(answer.filled ?? [:])"
                + (answer.notes!.isEmpty ? "" : " notes \(answer.notes!)") + (found.alternative.map { " or \($0.label)" } ?? "")
                + String(format: " %.1fs", answer.seconds!) + mark)
        }
        return ModelSubject(value: answer)
    }

    /// Whether `ids` (the found command's alike or alternative commands) build through the Builder's doors with `values`.
    static func builds(_ id: String?, _ filled: [String: String]) -> Bool {
        guard let id else { return true }
        let byKey = { (slots: [CommandFinder.Slot]) in
            Dictionary(uniqueKeysWithValues: slots.compactMap { slot in filled[slot.label].map { (slot.key, $0) } })
        }
        let slots = FinderMenu.menu.commands.first { $0.id == id }?.slots ?? []
        if let curated = CuratedCommand.all.first(where: { $0.id == id }) { return (try? curated.built(byKey(slots))) != nil }
        guard let command = FinderMenu.catalog.commands.first(where: { $0.id == id }) else { return false }
        return (try? GamCommands.catalogRead(command, values: byKey(slots))) != nil
    }

    var evaluators: Evaluators {
        Evaluator { input, subject in
            guard let truth = input.expected else { return right.ignore() }
            return truth.rightly(subject.value.found) ? right.passing() : right.failing(rationale: subject.value.found ?? "none")
        }
        Evaluator { input, subject in
            guard let truth = input.expected else { return offered.ignore() }
            let other = subject.value.alternative ?? []
            return truth.rightly(subject.value.found) || other.contains(where: truth.accept.contains) ? offered.passing() : offered.failing()
        }
        Evaluator { _, subject in asked.scoring(subject.value.alternative == nil ? 0 : 1) }
        // The first pick: a change when the right command is a curated change, a read when it's a read (nothing to say for
        // a request nothing fits).
        Evaluator { input, subject in
            guard let truth = input.expected, !truth.accept.isEmpty else { return intent.ignore() }
            let changes = Set(FinderMenu.menu.commands.filter(\.changes).map(\.id))
            let want: CommandFinder.Intent = truth.accept.contains(where: changes.contains) ? .change : .see
            return subject.value.picks?.first == want.rawValue ? intent.passing() : intent.failing(rationale: subject.value.picks?.first)
        }
        // Then the category, for a read.
        Evaluator { input, subject in
            let picks = subject.value.picks ?? []
            guard let truth = input.expected, picks.first == CommandFinder.Intent.see.rawValue, picks.count > 1 else { return category.ignore() }
            let categories = Set(FinderMenu.menu.reads.filter { truth.accept.contains($0.id) }.map(\.category))
            guard !categories.isEmpty else { return category.ignore() }
            return categories.contains(picks[1]) ? category.passing() : category.failing(rationale: picks[1])
        }
        Evaluator { input, subject in
            guard let truth = input.expected, truth.rightly(subject.value.found), subject.value.found != nil else { return slots.ignore() }
            return truth.rightSlots(subject.value.filled ?? [:]) ? slots.passing() : slots.failing(rationale: "\(subject.value.filled ?? [:])")
        }
        Evaluator { input, subject in
            guard let truth = input.expected else { return invented.ignore() }
            let made = truth.invented(subject.value.filled ?? [:])
            return invented.scoring(made.isEmpty ? 0 : 1, rationale: made.joined(separator: ", "))
        }
        Evaluator { _, subject in
            guard subject.value.found != nil else { return builds.ignore() }
            return Self.builds(subject.value.found, subject.value.filled ?? [:]) ? builds.passing() : builds.failing()
        }
        Evaluator { _, subject in seconds.scoring(subject.value.seconds ?? 0) }
        Evaluator { input, _ in
            guard let truth = input.expected else { return searchFirst.ignore() }
            return CommandFinderSampleTests.first(BuilderSearch.ids(truth.input), truth) ? searchFirst.passing() : searchFirst.failing()
        }
        Evaluator { input, _ in
            guard let truth = input.expected else { return searchTop3.ignore() }
            return CommandFinderSampleTests.top3(BuilderSearch.ids(truth.input), truth) ? searchTop3.passing() : searchTop3.failing()
        }
        Evaluator { input, _ in
            guard let truth = input.expected else { return rankedFirst.ignore() }
            return CommandFinderSampleTests.first(BuilderSearch.ranked(truth.input), truth) ? rankedFirst.passing() : rankedFirst.failing()
        }
        Evaluator { input, _ in
            guard let truth = input.expected else { return rankedTop3.ignore() }
            return CommandFinderSampleTests.top3(BuilderSearch.ranked(truth.input), truth) ? rankedTop3.passing() : rankedTop3.failing()
        }
    }

    func aggregateMetrics(using a: inout MetricsAggregator) {
        for metric in [right, offered, asked, intent, category, slots, invented, builds, seconds, searchFirst, searchTop3, rankedFirst, rankedTop3] {
            a.computeMean(of: metric)
        }
        a.computeMaximum(of: seconds)
    }
}

@Suite(.serialized) struct CommandFinderEvals {
    static let dev = FinderEvaluation(split: "dev")
    static let heldOut = FinderEvaluation(split: "heldout")

    @Test(.enabled(if: ModelRuns.on), .evaluates(CommandFinderEvals.dev, info: ["split": "dev"]))
    func devSplit() throws { try Self.report(EvaluationContext.current.result, Self.dev) }

    @Test(.enabled(if: ModelRuns.on), .evaluates(CommandFinderEvals.heldOut, info: ["split": "heldout"]))
    func heldOutSplit() throws { try Self.report(EvaluationContext.current.result, Self.heldOut) }

    /// One line of means for the log, the grouped summary, and the run saved.
    static func report(_ result: EvaluationResult, _ e: FinderEvaluation) throws {
        func mean(_ m: Metric) -> String { String(format: "%.2f", result.aggregateValue(.mean(of: m))) }
        print("EVAL finder \(e.split): right \(mean(e.right)) · right or offered \(mean(e.offered)) · asked \(mean(e.asked))"
            + " · see or change \(mean(e.intent)) · category \(mean(e.category))"
            + " · slots \(mean(e.slots)) · invented \(mean(e.invented)) · builds \(mean(e.builds)) · seconds \(mean(e.seconds)), most "
            + String(format: "%.1f", result.aggregateValue(.maximum(of: e.seconds))))
        print("EVAL search \(e.split): Builder first \(mean(e.searchFirst)) · top 3 \(mean(e.searchTop3)) · ranked first \(mean(e.rankedFirst)) · top 3 \(mean(e.rankedTop3))")
        print(result.groupedSummary)
        try FileManager.default.createDirectory(at: ModelRuns.results, withIntermediateDirectories: true)
        print("EVAL saved \(try result.saveJSON(to: ModelRuns.results).path)")
    }
}
#endif
