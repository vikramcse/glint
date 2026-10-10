import CoreGraphics
import Foundation

/// Image and video-frame preprocessing for EmbeddingGemma 2: aspect-preserving resize to a
/// patch budget, rescale to 0...1, patchify into (patch_row, patch_col, channel) vectors with
/// (x, y) positions, and pad to the budget. Port of the Gemma 4 / EmbeddingGemma 2 processors.
struct EG2ImageProcessor: Sendable {
    var patchSize = 16
    var poolingKernelSize = 3
    /// Soft tokens per image (280) or per video frame (140).
    var maxSoftTokens = 280

    var maxPatches: Int { maxSoftTokens * poolingKernelSize * poolingKernelSize }
    var patchDimension: Int { patchSize * patchSize * 3 }

    struct Output {
        /// maxPatches × patchDimension floats in 0...1, row-major.
        var patches: [Float]
        /// maxPatches × 2 positions (x, y); (-1, -1) for padding.
        var positions: [Int32]
        /// Soft tokens this image contributes (real patches / pool²).
        var softTokens: Int
    }

    /// The patch-budget size from `get_aspect_ratio_preserving_size`.
    func targetSize(height: Int, width: Int) -> (height: Int, width: Int) {
        let targetPixels = Double(maxPatches * patchSize * patchSize)
        let factor = (targetPixels / Double(height * width)).squareRoot()
        let side = poolingKernelSize * patchSize
        var targetHeight = Int((factor * Double(height) / Double(side)).rounded(.down)) * side
        var targetWidth = Int((factor * Double(width) / Double(side)).rounded(.down)) * side
        let maxSide = (maxPatches / (poolingKernelSize * poolingKernelSize)) * side
        if targetHeight == 0, targetWidth == 0 { return (side, side) }
        if targetHeight == 0 {
            targetHeight = side
            targetWidth = min(Int((Double(width) / Double(height)).rounded(.down)) * side, maxSide)
        } else if targetWidth == 0 {
            targetWidth = side
            targetHeight = min(Int((Double(height) / Double(width)).rounded(.down)) * side, maxSide)
        }
        return (targetHeight, targetWidth)
    }

    func process(_ image: CGImage) -> Output? {
        guard let rgb = RGBImage(image) else { return nil }
        return process(rgb)
    }

    func process(_ image: RGBImage) -> Output {
        let (height, width) = targetSize(height: image.height, width: image.width)
        let resized = (height == image.height && width == image.width) ? image : image.resizedBicubic(width: width, height: height)
        let rows = height / patchSize
        let columns = width / patchSize
        let realPatches = min(rows * columns, maxPatches)
        var patches = [Float](repeating: 0, count: maxPatches * patchDimension)
        var positions = [Int32](repeating: -1, count: maxPatches * 2)
        let scale: Float = 1 / 255
        var index = 0
        for row in 0..<rows {
            for column in 0..<columns where index < realPatches {
                var offset = index * patchDimension
                for y in 0..<patchSize {
                    let pixelRow = (row * patchSize + y) * width
                    for x in 0..<patchSize {
                        let pixel = (pixelRow + column * patchSize + x) * 3
                        patches[offset] = Float(resized.pixels[pixel]) * scale
                        patches[offset + 1] = Float(resized.pixels[pixel + 1]) * scale
                        patches[offset + 2] = Float(resized.pixels[pixel + 2]) * scale
                        offset += 3
                    }
                }
                positions[index * 2] = Int32(column)
                positions[index * 2 + 1] = Int32(row)
                index += 1
            }
        }
        return Output(patches: patches, positions: positions, softTokens: (rows * columns) / (poolingKernelSize * poolingKernelSize))
    }
}

/// 8-bit RGB pixels, row-major, no alpha.
struct RGBImage: Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Draws `image` into an sRGB bitmap (transparent areas over white, like PIL's RGB convert of RGBA is not;
    /// PIL drops alpha, so we composite over black to match).
    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let rgba = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            pixels[index * 3] = rgba[index * 4]
            pixels[index * 3 + 1] = rgba[index * 4 + 1]
            pixels[index * 3 + 2] = rgba[index * 4 + 2]
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// Pillow-compatible bicubic resize (a = -0.5, antialiased support, 22-bit fixed point,
    /// horizontal pass then vertical, 8-bit intermediate), so pixels match the reference.
    func resizedBicubic(width newWidth: Int, height newHeight: Int) -> RGBImage {
        var image = self
        if newWidth != width { image = image.resampled(horizontally: true, to: newWidth) }
        if newHeight != height { image = image.resampled(horizontally: false, to: newHeight) }
        return image
    }

    private static let precisionBits = 32 - 8 - 2

    private static func bicubic(_ value: Double) -> Double {
        let x = abs(value)
        let a = -0.5
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    /// Pillow's `precompute_coeffs` + `normalize_coeffs_8bpc`.
    private static func coefficients(inSize: Int, outSize: Int) -> (bounds: [(Int, Int)], kernel: [Int32], size: Int) {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = 2.0 * filterScale
        let size = Int(support.rounded(.up)) * 2 + 1
        var bounds: [(Int, Int)] = []
        var kernel = [Int32](repeating: 0, count: outSize * size)
        for output in 0..<outSize {
            let center = (Double(output) + 0.5) * scale
            var minimum = Int(center - support + 0.5)
            if minimum < 0 { minimum = 0 }
            var maximum = Int(center + support + 0.5)
            if maximum > inSize { maximum = inSize }
            let count = maximum - minimum
            var weights = [Double](repeating: 0, count: count)
            var total = 0.0
            for x in 0..<count {
                let weight = bicubic((Double(x + minimum) - center + 0.5) / filterScale)
                weights[x] = weight
                total += weight
            }
            for x in 0..<count {
                let normalized = total != 0 ? weights[x] / total : weights[x]
                let fixed = normalized * Double(1 << precisionBits)
                kernel[output * size + x] = Int32(fixed < 0 ? fixed - 0.5 : fixed + 0.5)
            }
            bounds.append((minimum, count))
        }
        return (bounds, kernel, size)
    }

    private func resampled(horizontally: Bool, to newSize: Int) -> RGBImage {
        let inSize = horizontally ? width : height
        let (bounds, kernel, size) = Self.coefficients(inSize: inSize, outSize: newSize)
        let outWidth = horizontally ? newSize : width
        let outHeight = horizontally ? height : newSize
        var output = [UInt8](repeating: 0, count: outWidth * outHeight * 3)
        let half = Int32(1 << (Self.precisionBits - 1))
        pixels.withUnsafeBufferPointer { source in
            for y in 0..<outHeight {
                for x in 0..<outWidth {
                    let target = horizontally ? x : y
                    let (start, count) = bounds[target]
                    var sums = (half, half, half)
                    for tap in 0..<count {
                        let weight = kernel[target * size + tap]
                        let sourceIndex = horizontally ? (y * width + start + tap) * 3 : ((start + tap) * width + x) * 3
                        sums.0 &+= Int32(source[sourceIndex]) &* weight
                        sums.1 &+= Int32(source[sourceIndex + 1]) &* weight
                        sums.2 &+= Int32(source[sourceIndex + 2]) &* weight
                    }
                    let destination = (y * outWidth + x) * 3
                    output[destination] = Self.clip8(sums.0)
                    output[destination + 1] = Self.clip8(sums.1)
                    output[destination + 2] = Self.clip8(sums.2)
                }
            }
        }
        return RGBImage(width: outWidth, height: outHeight, pixels: output)
    }

    private static func clip8(_ value: Int32) -> UInt8 {
        let shifted = value >> Int32(precisionBits)
        return UInt8(min(max(shifted, 0), 255))
    }
}
