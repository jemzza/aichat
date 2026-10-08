import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AIChat

struct ImageDownscalerTests {
    /// PNG заданного размера — как фото из библиотеки.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelSize(of data: Data) throws -> (type: String?, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (CGImageSourceGetType(source) as String?,
                properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test func largePhotoIsScaledDownToJPEG() throws {
        let jpeg = try #require(ImageDownscaler.jpeg(from: try png(width: 3000, height: 2000)))
        let size = try pixelSize(of: jpeg)
        #expect(size.type == UTType.jpeg.identifier)
        #expect(size.width == ImageDownscaler.maxPixelSize)
        #expect(size.height == 683)
    }

    @Test func smallPhotoIsNotEnlarged() throws {
        let jpeg = try #require(ImageDownscaler.jpeg(from: try png(width: 300, height: 200)))
        let size = try pixelSize(of: jpeg)
        #expect(size.width == 300)
        #expect(size.height == 200)
    }

    @Test func notAnImageIsRejected() {
        #expect(ImageDownscaler.jpeg(from: Data("hello".utf8)) == nil)
    }
}
