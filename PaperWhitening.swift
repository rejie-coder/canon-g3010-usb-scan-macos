import CoreImage
import Foundation

enum PaperWhitening {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.workingColorSpace: sRGB, .cacheIntermediates: false])
    private static let dimension = 64

    // Alpha measures how strongly a pixel resembles pale, neutral paper.
    // The lookup table supplies only a mask; the underlying ink color is
    // taken from the original image and is never looked up in the cube.
    private static let maskData: Data = {
        func ramp(_ low: Float, _ high: Float, _ value: Float) -> Float {
            let t = max(0, min(1, (value - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }
        let scale = 255 / Float(dimension - 1)
        var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let red = Float(r) * scale, green = Float(g) * scale, blue = Float(b) * scale
                    let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    let chroma = max(red, green, blue) - min(red, green, blue)
                    let light = ramp(148, 218, luma)
                    let neutral = 1 - ramp(9, 26, chroma)
                    values[4 * ((b * dimension + g) * dimension + r) + 3] = light * neutral
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }()

    static func apply(to image: CGImage, percent: Double) throws -> CGImage {
        guard percent > 0 else { return image }
        let source = CIImage(cgImage: image)
        let mask = source.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": dimension, "inputCubeData": maskData
        ]).applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(1, percent / 100))
        ])
        let white = CIImage(color: .white).cropped(to: source.extent)
        let adjusted = white.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: mask
        ])
        let outputSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        guard let result = context.createCGImage(adjusted, from: source.extent, format: .RGBA8, colorSpace: outputSpace) else {
            throw ScanError(message: "Could not adjust the paper tone. Try reducing Paper whitening.")
        }
        return result
    }
}
