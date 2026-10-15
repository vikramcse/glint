import CoreGraphics
import Foundation
import GlintCore
import GlintExtractors
import GlintStore
import ImageIO

/// `glint-eval faces <lfw-dir>`: measures face detection, identity separation and People
/// grouping on Labeled Faces in the Wild (one folder of photos per person).
///
/// Picks `people` identities with at least `perPerson` photos plus `strangers` identities seen
/// once (the faces in the background of a real library), feeds them to `FaceClusters` in a
/// shuffled order, and reports pairwise precision (faces grouped together really are one
/// person) and recall (one person's faces end up together) for each join threshold.
struct FaceEval {
    var root: URL
    var people = 80
    var perPerson = 10
    var strangers = 400
    var thresholds: [Float] = [0.35, 0.4, 0.45, 0.5, 0.55]

    func run() throws {
        let analyzer = FaceAnalyzer(minimumFaceSide: 40, minimumQuality: 0, maxFaces: 1)
        guard FaceAnalyzer.isAvailable else { fail("the SFace model did not load") }
        let samples = try pickSamples()
        var faces: [(identity: Int, print: [Float])] = []
        var qualities: [Float] = []
        var missed = 0
        let start = Date()
        for sample in samples {
            guard let image = Self.load(sample.url), let face = analyzer.faces(in: image).first else {
                missed += 1
                continue
            }
            faces.append((sample.identity, face.print))
            qualities.append(face.quality)
        }
        qualities.sort()
        let perFace = Date().timeIntervalSince(start) * 1_000 / Double(max(samples.count, 1))
        print(String(format: "%d photos, %d faces (%d missed), %.1f ms per photo", samples.count, faces.count, missed, perFace))
        if !qualities.isEmpty {
            let at = { (fraction: Double) in qualities[min(qualities.count - 1, Int(Double(qualities.count) * fraction))] }
            print(String(format: "capture quality:  p1 %.2f  p5 %.2f  p25 %.2f  p50 %.2f", at(0.01), at(0.05), at(0.25), at(0.5)))
        }
        printPairStats(faces)

        printSweep(faces)
    }

    /// Pairwise precision and recall of the grouping for each join threshold.
    private func printSweep(_ faces: [(identity: Int, print: [Float])]) {
        var generator = SeededGenerator(seed: 7)
        let shuffled = faces.shuffled(using: &generator)
        print("\njoin   merge   precision   recall   people found (true \(people + strangers))")
        for threshold in thresholds {
            var clusters = FaceClusters(joinThreshold: threshold, mergeThreshold: threshold + 0.05)
            var touched: Set<Int> = []
            let assigned = shuffled.map { face -> Int in
                let group = clusters.assign(face.print)
                touched.insert(group)
                return group
            }
            clusters.mergeClose(touched)
            let labels = assigned.map(clusters.resolve)
            let (precision, recall) = Self.pairScores(truth: shuffled.map(\.identity), predicted: labels)
            print(
                String(
                    format: "%.2f   %.2f    %.3f       %.3f    %d", threshold, threshold + 0.05, precision, recall,
                    Set(labels).count))
        }
    }

    private func pickSamples() throws -> [(identity: Int, url: URL)] {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: root.path).sorted()
        var samples: [(Int, URL)] = []
        var regulars = 0
        var singles = 0
        for name in names {
            let folder = root.appendingPathComponent(name)
            let files = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            if files.count >= perPerson, regulars < people {
                samples += files.prefix(perPerson).map { (samples.count, folder.appendingPathComponent($0)) }.map { (regulars, $0.1) }
                regulars += 1
            } else if files.count == 1, singles < strangers {
                samples.append((people + singles, folder.appendingPathComponent(files[0])))
                singles += 1
            }
        }
        return samples
    }

    private func printPairStats(_ faces: [(identity: Int, print: [Float])]) {
        var same: [Float] = []
        var different: [Float] = []
        for a in faces.indices {
            for b in faces.indices where b > a {
                let similarity = zip(faces[a].print, faces[b].print).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                if faces[a].identity == faces[b].identity { same.append(similarity) } else { different.append(similarity) }
            }
        }
        same.sort()
        different.sort()
        func at(_ values: [Float], _ fraction: Double) -> Float { values[min(values.count - 1, Int(Double(values.count) * fraction))] }
        guard !same.isEmpty, !different.isEmpty else { return }
        print(
            String(
                format: "same person:      p5 %.3f  p50 %.3f\ndifferent people: p99 %.3f  p99.9 %.3f", at(same, 0.05), at(same, 0.5),
                at(different, 0.99), at(different, 0.999)))
    }

    /// Pair-counting precision and recall of a clustering against the true identities.
    static func pairScores(truth: [Int], predicted: [Int]) -> (precision: Double, recall: Double) {
        var bothSame = 0
        var predictedSame = 0
        var trulySame = 0
        for a in truth.indices {
            for b in truth.indices where b > a {
                let isTrue = truth[a] == truth[b]
                let isPredicted = predicted[a] == predicted[b]
                if isTrue { trulySame += 1 }
                if isPredicted { predictedSame += 1 }
                if isTrue && isPredicted { bothSame += 1 }
            }
        }
        return (Double(bothSame) / Double(max(predictedSame, 1)), Double(bothSame) / Double(max(trulySame, 1)))
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
