import Foundation
import Metal

/// One contiguous, growable row-major matrix of 8-bit quantized vectors.
///
/// Each row holds `dimension` signed bytes (padded to a multiple of 4) followed by its Float32
/// scale: value ≈ byte × scale, with the scale set so the row's largest magnitude maps to 127.
/// That halves memory against Float16 with no measurable retrieval loss (glint-eval, COCO
/// photo benchmark: nDCG and precision within noise).
///
/// On Apple silicon the storage is a shared-mode `MTLBuffer`, so the same memory is read by
/// the GPU scan and written by the CPU on upsert with no copies (unified memory). Without
/// Metal it falls back to a plain page-aligned allocation for the Accelerate scan.
final class VectorMatrix {
    let dimension: Int
    /// Bytes of quantized values per row, padded so the scale that follows is 4-byte aligned.
    let paddedDimension: Int
    /// Bytes per row: quantized values plus the scale.
    let rowStride: Int
    private(set) var rows = 0
    private(set) var capacity: Int
    private(set) var buffer: (any MTLBuffer)?
    private var heap: UnsafeMutableRawPointer?
    private let device: (any MTLDevice)?

    init(dimension: Int, initialCapacity: Int = 1_024, device: (any MTLDevice)?) {
        self.dimension = dimension
        paddedDimension = (dimension + 3) / 4 * 4
        rowStride = paddedDimension + MemoryLayout<Float>.size
        self.device = device
        capacity = max(16, initialCapacity)
        allocate(capacity: capacity, copyingRows: 0, from: nil)
    }

    deinit { heap?.deallocate() }

    var base: UnsafeMutableRawPointer {
        // `allocate` always sets one of the two.
        (buffer?.contents() ?? heap).unsafelyUnwrapped
    }

    var byteCount: Int { capacity * rowStride }

    /// The quantized values of a row.
    func values(of row: Int) -> UnsafeMutablePointer<Int8> {
        (base + row * rowStride).assumingMemoryBound(to: Int8.self)
    }

    /// The scale of a row.
    func scale(of row: Int) -> Float {
        (base + row * rowStride + paddedDimension).load(as: Float.self)
    }

    /// Appends a row and returns its index.
    func append(_ values: [Float]) -> Int {
        if rows == capacity { grow() }
        write(values, at: rows)
        rows += 1
        return rows - 1
    }

    func write(_ values: [Float], at row: Int) {
        let peak = values.prefix(dimension).lazy.map(abs).max() ?? 0
        let scale = peak > 0 ? peak / 127 : 0
        let destination = self.values(of: row)
        for index in 0..<paddedDimension {
            guard index < dimension, index < values.count, scale > 0 else {
                destination[index] = 0
                continue
            }
            destination[index] = Int8(max(-127, min(127, (values[index] / scale).rounded())))
        }
        (base + row * rowStride + paddedDimension).storeBytes(of: scale, as: Float.self)
    }

    /// Moves the last row into `row` (swap-remove) and shrinks by one.
    func removeBySwappingLast(_ row: Int) {
        let last = rows - 1
        if row != last {
            (base + row * rowStride).copyMemory(from: base + last * rowStride, byteCount: rowStride)
        }
        rows -= 1
    }

    func removeAll() { rows = 0 }

    /// A row's values, dequantized.
    func row(_ index: Int) -> [Float] {
        let source = values(of: index)
        let scale = scale(of: index)
        return (0..<dimension).map { Float(source[$0]) * scale }
    }

    private func grow() {
        allocate(capacity: capacity * 2, copyingRows: rows, from: base)
    }

    private func allocate(capacity newCapacity: Int, copyingRows count: Int, from old: UnsafeMutableRawPointer?) {
        let bytes = newCapacity * rowStride
        var newBuffer: (any MTLBuffer)?
        var newHeap: UnsafeMutableRawPointer?
        if let device, let made = device.makeBuffer(length: bytes, options: .storageModeShared) {
            newBuffer = made
        } else {
            newHeap = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16_384)
        }
        let destination = (newBuffer?.contents() ?? newHeap).unsafelyUnwrapped
        if let old, count > 0 {
            destination.copyMemory(from: old, byteCount: count * rowStride)
        }
        heap?.deallocate()
        buffer = newBuffer
        heap = newHeap
        capacity = newCapacity
    }
}
