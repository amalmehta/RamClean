import CoreML
import CreateML
import Foundation

public enum Label: String, Codable, Sendable {
    case deadweight, keep
}

/// One answer you gave: the app's features at that moment, and whether you quit it or kept it.
public struct TrainingExample: Codable, Equatable, Sendable {
    public var date: Date
    public var features: FeatureVector
    public var label: Label
    /// "notification", "window", "menu bar" or "regret" (reopened soon after a quit).
    public var source: String

    public init(date: Date, features: FeatureVector, label: Label, source: String) {
        self.date = date; self.features = features; self.label = label; self.source = source
    }
}

public struct ModelStatus: Equatable, Sendable {
    public var isTrained = false
    public var examples = 0
    public var deadweightExamples = 0
    public var keepExamples = 0
    /// Accuracy on held-out answers (every fifth one), once there are 20+.
    public var holdoutAccuracy: Double?
    public var trainedAt: Date?
    public var message = "Waiting for your first answers"
    /// How much the model counts vs. the rule of thumb (0…0.85).
    public var modelWeight = 0.0

    public init() {}
}

/// A Create ML boosted-tree classifier trained on your own answers, on this Mac.
/// Until there are enough answers of both kinds it stays untrained and RamClean
/// relies on `HeuristicScorer`; afterwards the two are blended, leaning on the
/// model more as answers accumulate.
public final class DeadweightModel {
    public static let minExamples = 8
    public static let minPerClass = 3

    public private(set) var examples: [TrainingExample] = []
    public private(set) var status = ModelStatus()
    private var model: MLModel?
    private var probabilityOutput: String?
    private var knownIDs: Set<String> = []
    /// Stand-in for apps the model has never seen an answer about.
    static let otherApp = "_other"
    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("training.jsonl")
        if let data = try? Data(contentsOf: fileURL) {
            examples = data.split(separator: 0x0A).compactMap { try? HabitStore.decoder.decode(TrainingExample.self, from: Data($0)) }
        }
        refreshCounts()
    }

    public func add(_ example: TrainingExample) {
        lock.lock(); defer { lock.unlock() }
        examples.append(example)
        persist()
        refreshCounts()
    }

    /// You reopened an app RamClean quit: that answer was wrong, so flip it to "keep".
    @discardableResult
    public func relabelLatest(key: String, since: Date, to label: Label) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = examples.lastIndex(where: { $0.features.bundleID == key && $0.date >= since }) else { return false }
        examples[i].label = label
        examples[i].source = "regret"
        persist()
        refreshCounts()
        return true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        examples = []; model = nil; probabilityOutput = nil; knownIDs = []
        try? FileManager.default.removeItem(at: fileURL)
        status = ModelStatus()
    }

    /// Trains synchronously; call off the main thread.
    @discardableResult
    public func train() -> ModelStatus {
        lock.lock()
        let rows = examples
        lock.unlock()

        var s = ModelStatus()
        s.examples = rows.count
        s.deadweightExamples = rows.filter { $0.label == .deadweight }.count
        s.keepExamples = rows.count - s.deadweightExamples
        guard rows.count >= Self.minExamples, s.deadweightExamples >= Self.minPerClass, s.keepExamples >= Self.minPerClass else {
            s.message = "Needs \(Self.minExamples)+ answers with at least \(Self.minPerClass) quits and \(Self.minPerClass) keeps — using rules of thumb"
            setStatus(s, model: nil, output: nil)
            return s
        }
        do {
            if rows.count >= 20 {
                let test = rows.enumerated().filter { $0.offset % 5 == 4 }.map(\.element)
                let train = rows.enumerated().filter { $0.offset % 5 != 4 }.map(\.element)
                if Set(train.map(\.label)).count == 2 {
                    let holdout = try Self.fit(train)
                    let seen = Set(train.map(\.features.bundleID))
                    let metrics = holdout.evaluation(on: try Self.table(test.map { Self.generalized($0, known: seen) }))
                    if metrics.isValid { s.holdoutAccuracy = 1 - metrics.classificationError }
                }
            }
            let classifier = try Self.fit(rows)
            let mlModel = classifier.model
            let output = mlModel.modelDescription.predictedProbabilitiesName
                ?? mlModel.modelDescription.outputDescriptionsByName.first { $0.value.type == .dictionary }?.key
            s.isTrained = true
            s.trainedAt = Date()
            s.modelWeight = min(0.85, Double(rows.count) / 40)
            s.message = "Trained on \(rows.count) answers"
            setStatus(s, model: mlModel, output: output, known: Set(rows.map(\.features.bundleID)))
        } catch {
            s.message = "Training failed: \(error.localizedDescription)"
            setStatus(s, model: nil, output: nil)
        }
        return s
    }

    /// The model's probability that this app is deadweight, or nil when untrained.
    public func probability(_ f: FeatureVector) -> Double? {
        lock.lock()
        let m = model, out = probabilityOutput, known = knownIDs
        lock.unlock()
        guard let m, let out else { return nil }
        var dict: [String: Any] = f.numericValues
        dict["bundleID"] = known.contains(f.bundleID) ? f.bundleID : Self.otherApp
        guard let input = try? MLDictionaryFeatureProvider(dictionary: dict),
              let result = try? m.prediction(from: input),
              let probs = result.featureValue(for: out)?.dictionaryValue else { return nil }
        return probs[Label.deadweight.rawValue as NSString]?.doubleValue
            ?? probs.first { ($0.key as? String) == Label.deadweight.rawValue }?.value.doubleValue
    }

    /// Final score: rule of thumb, blended with the model once it is trained.
    public func score(_ f: FeatureVector) -> (value: Double, usedModel: Bool) {
        let h = HeuristicScorer.score(f)
        guard let p = probability(f) else { return (h, false) }
        let w = status.modelWeight
        return (w * p + (1 - w) * h, true)
    }

    // MARK: - Private

    private static func table(_ rows: [TrainingExample]) throws -> MLDataTable {
        var cols: [String: MLDataValueConvertible] = [:]
        for key in FeatureVector.numericKeys { cols[key] = rows.map { $0.features.numericValues[key] ?? 0 } }
        cols["bundleID"] = rows.map(\.features.bundleID)
        cols["label"] = rows.map(\.label.rawValue)
        return try MLDataTable(dictionary: cols)
    }

    private static func generalized(_ e: TrainingExample, known: Set<String>) -> TrainingExample {
        guard !known.contains(e.features.bundleID) else { return e }
        var copy = e
        copy.features.bundleID = otherApp
        return copy
    }

    /// Every answer is also added once as "_other", so the model learns a general
    /// pattern it can apply to apps you haven't answered about yet.
    private static func fit(_ rows: [TrainingExample]) throws -> MLBoostedTreeClassifier {
        let rows = rows + rows.map { generalized($0, known: []) }
        var params = MLBoostedTreeClassifier.ModelParameters()
        params.validation = .none
        params.maxDepth = 4
        params.maxIterations = 40
        params.minChildWeight = 0.1
        params.randomSeed = 42
        return try MLBoostedTreeClassifier(
            trainingData: try table(rows), targetColumn: "label",
            featureColumns: FeatureVector.numericKeys + ["bundleID"], parameters: params)
    }

    private func setStatus(_ s: ModelStatus, model m: MLModel?, output: String?, known: Set<String> = []) {
        lock.lock(); defer { lock.unlock() }
        status = s; model = m; probabilityOutput = output; knownIDs = known
    }

    private func refreshCounts() {
        status.examples = examples.count
        status.deadweightExamples = examples.filter { $0.label == .deadweight }.count
        status.keepExamples = examples.count - status.deadweightExamples
    }

    private func persist() {
        var data = Data()
        for e in examples {
            if let line = try? HabitStore.encoder.encode(e) { data.append(line); data.append(0x0A) }
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
