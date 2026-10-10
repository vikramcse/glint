import Foundation

/// Encodes vectors as little-endian half-precision blobs, halving storage versus Float32.
public enum VectorCodec {
    public static func encode(_ values: [Float]) -> Data {
        var halves = values.map { Float16($0) }
        return Data(bytes: &halves, count: halves.count * MemoryLayout<Float16>.size)
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float16>.size
        return data.withUnsafeBytes { buffer in
            let halves = buffer.bindMemory(to: Float16.self)
            return (0..<count).map { Float(halves[$0]) }
        }
    }

    /// Waveform peaks are stored as 8-bit values; 256 levels is plenty for a 30 pt tall view.
    public static func encodeWaveform(_ peaks: [Float]) -> Data {
        Data(peaks.map { UInt8((min(max($0, 0), 1) * 255).rounded()) })
    }

    public static func decodeWaveform(_ data: Data) -> [Float] {
        data.map { Float($0) / 255 }
    }
}
