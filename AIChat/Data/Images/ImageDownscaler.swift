import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Готовит фото к отправке: уменьшает до `maxPixelSize` по длинной стороне и пережимает в JPEG.
/// Метаданные (EXIF, геопозиция) не переносятся — в базу и в сеть уходят только пиксели.
enum ImageDownscaler {
    /// Хватает vision-модели и держит вложение в базе в пределах ~100–300 KB.
    static let maxPixelSize = 1024
    static let jpegQuality = 0.7

    /// - Returns: JPEG или `nil`, если это не картинка (или её не удалось прочитать).
    static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Учитываем ориентацию из EXIF — иначе фото с камеры лягут на бок.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
