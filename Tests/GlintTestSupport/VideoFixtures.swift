@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

extension Fixtures {
    /// Writes an H.264 MP4 whose frames change color every second, with an optional AAC sine
    /// tone. With `includeVideo: false` it writes an audio-only MP4.
    @discardableResult
    public static func writeVideo(
        duration: Double, named name: String = "clip.mp4", in directory: URL,
        size: CGSize = CGSize(width: 320, height: 240), framesPerSecond: Int = 10,
        includeVideo: Bool = true, includeAudio: Bool = true
    ) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if includeVideo {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
            videoInput = input
        }

        let sampleRate = 44_100
        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? FixtureError.cannotCreate("video writer") }
        writer.startSession(atSourceTime: .zero)

        // Feed whichever input is ready; the writer interleaves, and waiting on one input while
        // it waits for the other would stall.
        let frameCount = includeVideo ? Int((duration * Double(framesPerSecond)).rounded(.up)) : 0
        let totalSamples = includeAudio ? Int(duration * Double(sampleRate)) : 0
        let samplesPerBuffer = sampleRate / 10
        var nextFrame = 0
        var nextSample = 0
        var idleIterations = 0
        while nextFrame < frameCount || nextSample < totalSamples {
            var progressed = false
            if nextFrame < frameCount, let videoInput, let adaptor, videoInput.isReadyForMoreMediaData {
                let second = nextFrame / framesPerSecond
                let buffer = try pixelBuffer(size: size, hue: Double(second % 6) / 6)
                let time = CMTime(value: CMTimeValue(nextFrame), timescale: CMTimeScale(framesPerSecond))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? FixtureError.cannotCreate("video frame")
                }
                nextFrame += 1
                if nextFrame == frameCount { videoInput.markAsFinished() }
                progressed = true
            }
            if nextSample < totalSamples, let audioInput, audioInput.isReadyForMoreMediaData {
                let count = min(samplesPerBuffer, totalSamples - nextSample)
                let buffer = try toneSampleBuffer(start: nextSample, count: count, sampleRate: sampleRate)
                guard audioInput.append(buffer) else { throw writer.error ?? FixtureError.cannotCreate("audio buffer") }
                nextSample += count
                if nextSample == totalSamples { audioInput.markAsFinished() }
                progressed = true
            }
            if progressed {
                idleIterations = 0
            } else {
                idleIterations += 1
                if idleIterations > 2_000 { throw FixtureError.cannotCreate("writer inputs stalled") }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.cannotCreate("video file") }
        return url
    }

    private static func pixelBuffer(size: CGSize, hue: Double) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard let buffer else { throw FixtureError.cannotCreate("pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { throw FixtureError.cannotCreate("frame context") }
        let red = 0.5 + 0.5 * cos(2 * .pi * hue)
        let green = 0.5 + 0.5 * cos(2 * .pi * (hue - 1.0 / 3))
        let blue = 0.5 + 0.5 * cos(2 * .pi * (hue - 2.0 / 3))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: size.width / 4, y: size.height / 4, width: size.width / 2, height: size.height / 2))
        return buffer
    }

    private static func toneSampleBuffer(start: Int, count: Int, sampleRate: Int) throws -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let value = sin(2 * .pi * 440 * Double(start + index) / Double(sampleRate)) * 0.5
            samples[index] = Int16(value * Double(Int16.max))
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        let length = count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block
        )
        guard let format, let block else { throw FixtureError.cannotCreate("audio block") }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { throw FixtureError.cannotCreate("audio copy") }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { throw FixtureError.cannotCreate("audio sample buffer") }
        return sampleBuffer
    }
}
