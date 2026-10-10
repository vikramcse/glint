import Accelerate
import Foundation
import GlintCore
import Metal

/// Computes the dot product of a query with every row of a `VectorMatrix`.
protocol VectorScanner {
    func scores(_ matrix: VectorMatrix, query: [Float]) -> [Float]
}

/// Single-pass GPU scan: one thread per row, half-precision rows, float accumulation.
final class MetalVectorScanner: VectorScanner {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private var scoreBuffer: (any MTLBuffer)?

    private static let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void dot_rows(device const half4 *matrix [[buffer(0)]],
                             constant float4 *query [[buffer(1)]],
                             device float *scores [[buffer(2)]],
                             constant uint &quads [[buffer(3)]],
                             constant uint &rows [[buffer(4)]],
                             uint gid [[thread_position_in_grid]]) {
            if (gid >= rows) { return; }
            device const half4 *row = matrix + gid * quads;
            float4 acc = 0.0f;
            for (uint i = 0; i < quads; i++) {
                acc += float4(row[i]) * query[i];
            }
            scores[gid] = acc.x + acc.y + acc.z + acc.w;
        }
        """

    /// Fails when there is no Metal device or the kernel cannot compile.
    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let function = library.makeFunction(name: "dot_rows") else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            Log.search.error("Metal scan unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    var metalDevice: any MTLDevice { device }

    func scores(_ matrix: VectorMatrix, query: [Float]) -> [Float] {
        let rows = matrix.rows
        guard rows > 0 else { return [] }
        guard matrix.dimension % 4 == 0, let matrixBuffer = matrix.buffer,
            let output = scoreBuffer(rows: rows),
            let commands = queue.makeCommandBuffer(),
            let encoder = commands.makeComputeCommandEncoder()
        else {
            return AccelerateVectorScanner().scores(matrix, query: query)
        }
        var quads = UInt32(matrix.dimension / 4)
        var rowCount = UInt32(rows)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(matrixBuffer, offset: 0, index: 0)
        query.withUnsafeBytes { encoder.setBytes($0.baseAddress.unsafelyUnwrapped, length: $0.count, index: 1) }
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&quads, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.setBytes(&rowCount, length: MemoryLayout<UInt32>.size, index: 4)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(
            MTLSize(width: rows, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let pointer = output.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: rows))
    }

    private func scoreBuffer(rows: Int) -> (any MTLBuffer)? {
        let bytes = rows * MemoryLayout<Float>.stride
        if let scoreBuffer, scoreBuffer.length >= bytes { return scoreBuffer }
        scoreBuffer = device.makeBuffer(length: max(bytes, 4_096) * 2, options: .storageModeShared)
        return scoreBuffer
    }
}

/// CPU scan: converts blocks of half rows to float and runs one BLAS matrix-vector multiply per block.
struct AccelerateVectorScanner: VectorScanner {
    var blockRows = 2_048

    func scores(_ matrix: VectorMatrix, query: [Float]) -> [Float] {
        let rows = matrix.rows
        let dimension = matrix.dimension
        guard rows > 0 else { return [] }
        var scores = [Float](repeating: 0, count: rows)
        var block = [Float](repeating: 0, count: blockRows * dimension)
        var start = 0
        while start < rows {
            let count = min(blockRows, rows - start)
            let elements = count * dimension
            let source = matrix.pointer + start * dimension
            block.withUnsafeMutableBufferPointer { floats in
                var input = vImage_Buffer(
                    data: UnsafeMutableRawPointer(source), height: 1, width: vImagePixelCount(elements),
                    rowBytes: elements * MemoryLayout<Float16>.stride)
                var output = vImage_Buffer(
                    data: floats.baseAddress, height: 1, width: vImagePixelCount(elements),
                    rowBytes: elements * MemoryLayout<Float>.stride)
                vImageConvert_Planar16FtoPlanarF(&input, &output, 0)
            }
            scores.withUnsafeMutableBufferPointer { output in
                block.withUnsafeBufferPointer { floats in
                    query.withUnsafeBufferPointer { vector in
                        // (count x dimension) * (dimension x 1) -> (count x 1)
                        vDSP_mmul(
                            floats.baseAddress.unsafelyUnwrapped, 1, vector.baseAddress.unsafelyUnwrapped, 1,
                            output.baseAddress.unsafelyUnwrapped + start, 1,
                            vDSP_Length(count), 1, vDSP_Length(dimension)
                        )
                    }
                }
            }
            start += count
        }
        return scores
    }
}
