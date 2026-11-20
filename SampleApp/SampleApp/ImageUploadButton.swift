import SwiftUI
import PhotosUI

/// An image picked from the photo library.
struct PickedImage {
    let name: String
    let data: Data
}

/// A button that picks one image from the photo library and hands its data to `onPick`.
@available(iOS 16.0, *)
struct ImageUploadButton: View {
    let onPick: (Result<PickedImage, any Error>) -> Void

    @State private var selection: PhotosPickerItem?

    var body: some View {
        PhotosPicker("Pick an image and upload…", selection: $selection, matching: .images)
            .task(id: selection) {
                guard let item = selection else {
                    return
                }
                // Picking another image while this one loads cancels this task and starts one for the new
                // image. That one owns the selection then, so a cancelled load neither reports nor clears it.
                defer {
                    if selection == item {
                        selection = nil
                    }
                }

                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    guard !Task.isCancelled else {
                        return
                    }
                    let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "img"
                    onPick(.success(PickedImage(name: "image.\(fileExtension)", data: data)))
                } catch {
                    if !Task.isCancelled {
                        onPick(.failure(error))
                    }
                }
            }
    }
}
