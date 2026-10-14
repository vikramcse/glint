import Foundation
import GlintCore
import GlintTestSupport
import Testing
import UniformTypeIdentifiers

@testable import GlintExtractors

/// Returns fixed segments, standing in for on-device speech recognition.
struct FakeTranscriber: Transcriber {
    var segments: [TranscriptSegment]
    func transcribe(_ url: URL) async throws -> [TranscriptSegment] { segments }
}

@Suite("AudioExtractor")
struct AudioExtractorTests {
    let directory: TemporaryDirectory

    init() throws { directory = try TemporaryDirectory() }

    @Test func windowsA25SecondTone() async throws {
        let url = try Fixtures.writeToneWAV(duration: 25, channels: 2, in: directory.url)
        let chunks = try await collect(AudioExtractor(), url)
        #expect(chunks.count == 3)
        #expect(chunks.map(\.ordinal) == [0, 1, 2])

        let ranges = chunks.compactMap(\.locator.timeRange)
        #expect(ranges.map(\.lowerBound) == [0, 8, 16])
        #expect(abs(ranges[0].upperBound - 10) < 0.01)
        #expect(abs(ranges[2].upperBound - 25) < 0.05)

        guard case .audio(let clip) = chunks[0].input else {
            Issue.record("Expected an audio input")
            return
        }
        #expect(clip.sampleRate == 16_000)
        #expect(abs(clip.samples.count - 160_000) < 50)
        #expect((clip.samples.map(abs).max() ?? 0) > 0.3)
        if case .audio(let last) = chunks[2].input {
            #expect(last.start == 16)
            #expect(abs(last.duration - 9) < 0.05)
        }

        let waveform = try #require(chunks[0].preview.waveform)
        #expect(waveform.count == 200)
        #expect(waveform.allSatisfy { (0...1).contains($0) })
        #expect(waveform.max() == 1)
        #expect(abs((chunks[0].preview.duration ?? 0) - 25) < 0.05)
        #expect(chunks[1].preview.waveform == nil)
    }

    @Test func windowMathCoversTheFile() {
        let windows = AudioAnalysis.windows(duration: 25, length: 10, overlap: 2)
        #expect(windows.map(\.start) == [0, 8, 16])
        #expect(AudioAnalysis.windows(duration: 3, length: 10, overlap: 2).map(\.end) == [3])
        #expect(AudioAnalysis.windows(duration: 0, length: 10, overlap: 2).isEmpty)
        #expect(AudioAnalysis.windows(duration: 10, length: 5, overlap: 0).map(\.start) == [0, 5])
    }

    @Test func transcriptBecomesTextAndInterleavedInput() async throws {
        let url = try Fixtures.writeToneWAV(duration: 12, in: directory.url)
        let transcriber = FakeTranscriber(segments: [
            TranscriptSegment(start: 1, end: 2, text: "the"),
            TranscriptSegment(start: 2, end: 3, text: "deadline"),
            TranscriptSegment(start: 11, end: 11.5, text: "friday"),
        ])
        let extractor = AudioExtractor(options: ExtractionOptions(transcriptionEnabled: true), transcriber: transcriber)
        let chunks = try await collect(extractor, url)
        #expect(chunks.map(\.text) == ["the deadline", "friday"])
        guard case .interleaved(let parts) = chunks[0].input else {
            Issue.record("Expected interleaved input")
            return
        }
        #expect(parts.count == 2)
    }

    @Test func soundLabelsDescribeTheirWindow() {
        let labels = [
            SoundLabel(start: 0, end: 1, name: "dog bark", confidence: 0.6),
            SoundLabel(start: 0.5, end: 1.5, name: "dog bark", confidence: 0.9),
            SoundLabel(start: 1, end: 2, name: "dog", confidence: 0.8),
            SoundLabel(start: 11, end: 12, name: "rain", confidence: 0.7),
        ]
        #expect(labels.text(from: 0, to: 10) == "Sounds: dog bark, dog")
        #expect(labels.text(from: 8, to: 12) == "Sounds: rain")
        #expect(labels.text(from: 3, to: 10) == nil)
        let crowded = (0..<8).map { SoundLabel(start: 0, end: 1, name: "sound \($0)", confidence: 0.5 + Double($0) / 100) }
        #expect(crowded.text(from: 0, to: 1) == "Sounds: sound 7, sound 6, sound 5, sound 4, sound 3")
    }

    @Test func soundLabelsLeaveTheAudioVectorAloneForKeywords() async throws {
        let url = try Fixtures.writeToneWAV(duration: 4, in: directory.url)
        let chunks = try await collect(AudioExtractor(options: ExtractionOptions(soundLabels: .keywords)), url)
        #expect(chunks.count == 1)
        guard case .audio = chunks[0].input else {
            Issue.record("Expected audio input: keyword labels must not change the embedding")
            return
        }
    }

    @Test func transcriberIgnoredWhenDisabled() async throws {
        let url = try Fixtures.writeToneWAV(duration: 4, in: directory.url)
        let transcriber = FakeTranscriber(segments: [TranscriptSegment(start: 0, end: 1, text: "hello")])
        let chunks = try await collect(AudioExtractor(transcriber: transcriber), url)
        #expect(chunks.first?.text == nil)
    }

    @Test func corruptAndEmptyFilesFail() async throws {
        let corrupt = try Fixtures.writeData(Data(repeating: 0x11, count: 4_096), named: "broken.wav", in: directory.url)
        try await expectExtractionError(.corrupt, AudioExtractor(), corrupt)
        let empty = try Fixtures.writeData(Data(), named: "empty.m4a", in: directory.url)
        try await expectExtractionError(.empty, AudioExtractor(), empty)
    }
}

@Suite("VideoExtractor")
struct VideoExtractorTests {
    let directory: TemporaryDirectory

    init() throws { directory = try TemporaryDirectory() }

    @Test func clipsA6SecondVideo() async throws {
        let url = try await Fixtures.writeVideo(duration: 6, in: directory.url)
        let chunks = try await collect(VideoExtractor(), url)
        #expect(chunks.count == 2)
        #expect(chunks.compactMap(\.locator.timeRange).map(\.lowerBound) == [0, 5])

        guard case .video(let first) = chunks[0].input, case .video(let second) = chunks[1].input else {
            Issue.record("Expected video inputs")
            return
        }
        #expect(first.frames.count == 5)
        #expect(second.frames.count == 1)
        #expect(first.frames.allSatisfy { max($0.width, $0.height) <= 512 })
        #expect(first.start == 0)
        #expect(first.end == 5)
        let audio = try #require(first.audio)
        #expect(audio.sampleRate == 16_000)
        #expect(abs(audio.duration - 5) < 0.1)
        #expect(abs((second.audio?.duration ?? 0) - 1) < 0.15)

        #expect(chunks.map(\.preview.thumbnailKey) == ["t0", "t5"])
        #expect(chunks.allSatisfy { $0.preview.thumbnail != nil })
        #expect(chunks[0].preview.waveform?.count == 200)
        #expect(abs((chunks[0].preview.duration ?? 0) - 6) < 0.1)
        #expect(chunks[1].preview.waveform == nil)
    }

    @Test func silentVideoHasNoAudio() async throws {
        let url = try await Fixtures.writeVideo(duration: 3, named: "silent.mp4", in: directory.url, includeAudio: false)
        let chunks = try await collect(VideoExtractor(), url)
        #expect(chunks.count == 1)
        guard case .video(let clip) = chunks[0].input else {
            Issue.record("Expected a video input")
            return
        }
        #expect(clip.audio == nil)
        #expect(clip.frames.count == 3)
    }

    @Test func audioOnlyMovieIsTreatedAsAudio() async throws {
        let url = try await Fixtures.writeVideo(duration: 4, named: "voice.mp4", in: directory.url, includeVideo: false)
        let chunks = try await collect(VideoExtractor(), url)
        #expect(chunks.count == 1)
        guard case .audio(let clip) = chunks[0].input else {
            Issue.record("Expected an audio input")
            return
        }
        #expect(abs(clip.duration - 4) < 0.15)
    }

    @Test func frameTimesSampleIntervalMidpoints() {
        #expect(VideoCursor.frameTimes(from: 0, to: 5, rate: 1) == [0.5, 1.5, 2.5, 3.5, 4.5])
        #expect(VideoCursor.frameTimes(from: 5, to: 5.3, rate: 1) == [5.15])
    }

    @Test func corruptFileFails() async throws {
        let corrupt = try Fixtures.writeData(Data(repeating: 0x00, count: 2_048), named: "broken.mov", in: directory.url)
        try await expectExtractionError(.corrupt, VideoExtractor(), corrupt)
    }
}

@Suite("ExtractorRegistry")
struct ExtractorRegistryTests {
    let registry = ExtractorRegistry.standard()

    @Test(arguments: [
        ("pdf", "PDFExtractor"),
        ("png", "ImageExtractor"),
        ("heic", "ImageExtractor"),
        ("mov", "VideoExtractor"),
        ("mp4", "VideoExtractor"),
        ("m4a", "AudioExtractor"),
        ("mp3", "AudioExtractor"),
        ("txt", "TextExtractor"),
        ("md", "TextExtractor"),
        ("swift", "TextExtractor"),
        ("rtf", "TextExtractor"),
        ("docx", "TextExtractor"),
        ("html", "TextExtractor"),
    ])
    func routesByType(pathExtension: String, expected: String) throws {
        let type = try #require(UTType(filenameExtension: pathExtension))
        let extractor = try #require(registry.extractor(for: type))
        #expect(String(describing: Swift.type(of: extractor)) == expected)
    }

    @Test func unsupportedTypesHaveNoExtractor() {
        #expect(registry.extractor(for: .zip) == nil)
        #expect(!registry.supports(.applicationBundle))
    }

    @Test func everyIndexableKindHasAnExtractor() {
        for type in [UTType.png, .pdf, .mpeg4Movie, .mp3, .plainText] {
            #expect(registry.supports(type))
        }
    }
}
