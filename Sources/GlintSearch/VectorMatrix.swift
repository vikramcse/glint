import Foundation
import Metal

/// One contiguous, growable row-major matrix of half-precision vectors.
///
/// On Apple silicon the storage is a shared-mode `MTLBuffer`, so the same memory is read by
/// the GPU scan and written by the CPU on upsert with no copies (unified memory). Without
/// Metal it falls back to a plain page-aligned allocation for the Accelerate scan.
final class VectorMatrix {
    let dimension: Int
    private(set) var rows = 0
    private(set) var capacity: Int
    private(set) var buffer: (any MTLBuffer)?
    private var heap: UnsafeMutableRawPointer?
    private let device: (any MTLDevice)?

    init(dimension: Int, initialCapacity: Int = 1_024, device: (any MTLDevice)?) {
        self.dimension = dimension
        self.device = device
        capacity = max(16, initialCapacity)
        allocate(capacity: capacity, copyingRows: 0, from: nil)
    }

    deinit { heap?.deallocate() }

    var pointer: UnsafeMutablePointer<Float16> {
        let raw = buffer?.contents() ?? heap ?? UnsafeMutableRawPointer(bitPattern: 0x10)
        // `raw` is never the sentinel: `allocate` always sets one of the two.
        return raw.unsafelyUnwrapped.assumingMemoryBound(to: Float16.self)
    }

    var byteCount: Int { capacity * dimension * MemoryLayout<Float16>.stride }

    /// Appends a row and returns its index.
    func append(_ values: [Float]) -> Int {
        if rows == capacity { grow() }
        write(values, at: rows)
        rows += 1
        return rows - 1
    }

    func write(_ values: [Float], at row: Int) {
        let destination = pointer + row * dimension
        for index in 0..<dimension {
            destination[index] = index < values.count ? Float16(values[index]) : 0
        }
    }

    /// Moves the last row into `row` (swap-remove) and shrinks by one.
    func removeBySwappingLast(_ row: Int) {
        let last = rows - 1
        if row != last {
            (pointer + row * dimension).update(from: pointer + last * dimension, count: dimension)
        }
        rows -= 1
    }

    func removeAll() { rows = 0 }

    func row(_ index: Int) -> [Float] {
        let source = pointer + index * dimension
        return (0..<dimension).map { Float(source[$0]) }
    }

    private func grow() {
        allocate(capacity: capacity * 2, copyingRows: rows, from: pointer)
    }

    private func allocate(capacity newCapacity: Int, copyingRows count: Int, from old: UnsafeMutablePointer<Float16>?) {
        let bytes = newCapacity * dimension * MemoryLayout<Float16>.stride
        var newBuffer: (any MTLBuffer)?
        var newHeap: UnsafeMutableRawPointer?
        if let device, let made = device.makeBuffer(length: bytes, options: .storageModeShared) {
            newBuffer = made
        } else {
            newHeap = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16_384)
        }
        let destination = (newBuffer?.contents() ?? newHeap).unsafelyUnwrapped
        if let old, count > 0 {
            destination.copyMemory(from: old, byteCount: count * dimension * MemoryLayout<Float16>.stride)
        }
        heap?.deallocate()
        buffer = newBuffer
        heap = newHeap
        capacity = newCapacity
    }
}
