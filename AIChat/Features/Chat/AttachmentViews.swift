import SwiftUI
import UIKit

/// Фото из вложения, обрезанное по квадрату. Декодируется вне главного потока и
/// уменьшается до размера на экране — лента не декодирует полный JPEG на каждый кадр.
struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    let side: CGFloat
    var cornerRadius: CGFloat = 12

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .frame(width: side, height: side)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.secondary.opacity(0.15))
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .accessibilityElement()
            .accessibilityLabel(Text("Photo"))
            .accessibilityAddTraits(.isImage)
            .task(id: attachment.id) {
                image = await Self.decode(attachment.jpegData, pixelSide: side * displayScale)
            }
    }

    private static func decode(_ data: Data, pixelSide: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let scale = pixelSide / min(image.size.width, image.size.height)
            guard scale < 1 else { return image }
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return await image.byPreparingThumbnail(ofSize: size) ?? image
        }.value
    }
}

/// Фото целиком — по нажатию на миниатюру в сообщении.
struct ImageViewer: View {
    let attachment: ImageAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(Text("Photo"))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .background(.appBackground)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: attachment.id) {
            let data = attachment.jpegData
            image = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
        }
    }
}
