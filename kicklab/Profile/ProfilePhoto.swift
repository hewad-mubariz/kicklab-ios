import PhotosUI
import SwiftUI
import UIKit

/// The person's own picture, kept on this device as a 512 px square.
enum ProfilePhoto {
    /// Bumped on every change so avatars reload.
    static let versionKey = "kicklab.profile.photoVersion"

    nonisolated static var url: URL {
        URL.applicationSupportDirectory.appending(path: "profile-photo.jpg")
    }

    static func load() -> UIImage? { UIImage(contentsOfFile: url.path) }

    /// Crops the picked image to a centred square, scales it down and stores it.
    nonisolated static func save(_ data: Data) throws {
        let jpeg = try jpeg(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: [.atomic, .completeFileProtection])
    }

    nonisolated static func jpeg(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let target: CGFloat = 512
        let scale = target / min(image.size.width, image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            image.draw(in: CGRect(x: (target - drawn.width) / 2, y: (target - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
        guard let jpeg = square.jpegData(compressionQuality: 0.86) else { throw CocoaError(.fileWriteUnknown) }
        return jpeg
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
        changed()
    }

    static func changed() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: versionKey) + 1, forKey: versionKey)
    }
}

/// A player's picture, or a placeholder when they have none.
struct PlayerAvatar: View {
    let name: String
    var isYou = false
    let size: CGFloat
    var remoteURL: URL? = nil

    var body: some View {
        AsyncImage(url: remoteURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                PlayerPlaceholder(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Initials on a club colour picked from the name, so the same player always looks the same.
/// Without a name it falls back to the profile mark.
struct PlayerPlaceholder: View {
    let name: String
    let size: CGFloat

    private static let colours: [Color] = [
        Color(red: 0.29, green: 0.4, blue: 0.14), Color(red: 0.25, green: 0.32, blue: 0.4),
        Color(red: 0.6, green: 0.35, blue: 0.24), Color(red: 0.15, green: 0.41, blue: 0.39),
        Color(red: 0.4, green: 0.25, blue: 0.37), Color(red: 0.55, green: 0.46, blue: 0.27)
    ]

    private var initials: String {
        name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var colour: Color {
        Self.colours[name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.colours.count]
    }

    var body: some View {
        ZStack {
            if initials.isEmpty {
                Circle().fill(Color(white: 0.9))
                ProfileMonolineMark()
                    .environment(\.colorScheme, .light)
                    .frame(width: size * 0.5, height: size * 0.5)
            } else {
                Circle().fill(LinearGradient(colors: [colour.mix(with: .white, by: 0.18), colour],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(initials)
                    .font(TrainingHomeStyle.display(size * 0.46, relativeTo: .title))
                    .foregroundStyle(.white)
                    .padding(.top, size * 0.08)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The profile's avatar circle: tap to pick a photo, press and hold to remove it.
struct ProfilePhotoPicker<Placeholder: View>: View {
    let size: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder
    @AppStorage(ProfilePhoto.versionKey) private var version = 0
    @State private var item: PhotosPickerItem?
    @State private var photo: UIImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let photo {
                        Image(uiImage: photo).resizable().scaledToFill()
                            .transition(.sessionPop(scale: 0.8))
                    } else {
                        placeholder()
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                Image(systemName: photo == nil ? "camera.fill" : "pencil")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(TrainingHomeStyle.buttonInk)
                    .frame(width: 28, height: 28)
                    .background(TrainingHomeStyle.lime, in: .circle)
                    .overlay { Circle().strokeBorder(TrainingHomeStyle.background(scheme), lineWidth: 3) }
                    .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(SessionPressStyle(scale: 0.94))
        .contextMenu {
            if photo != nil {
                Button("Remove photo", systemImage: "trash", role: .destructive) { ProfilePhoto.remove() }
            }
        }
        .task(id: version) {
            let loaded = ProfilePhoto.load()
            withAnimation(SessionMotion.pop) { photo = loaded }
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self) {
                    let saved = await Task.detached(priority: .userInitiated) { (try? ProfilePhoto.save(data)) != nil }.value
                    if saved { ProfilePhoto.changed() }
                }
                item = nil
            }
        }
        .accessibilityLabel(photo == nil ? "Add profile photo" : "Change profile photo")
        .accessibilityIdentifier("profile-photo")
    }
}
