import SwiftUI
import PhotosUI
import UIKit

struct VOICEGradient: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.95), Color.purple.opacity(0.75)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension View {
    @ViewBuilder
    func voiceGlass(cornerRadius: CGFloat = 24) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    func voiceCard(cornerRadius: CGFloat = 24) -> some View {
        self
            .padding(16)
            .voiceGlass(cornerRadius: cornerRadius)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
    }
}

enum VoiceAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Системная"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct VOICEPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                VOICEGradient()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .opacity(configuration.isPressed ? 0.78 : 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct VOICETextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14)
            .voiceGlass(cornerRadius: 16)
    }
}

struct VOICEEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct AvatarView: View {
    @EnvironmentObject private var store: AppStore

    let path: String?
    let displayName: String
    var size: CGFloat = 44

    @State private var signedURL: URL?

    var body: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)

            if let signedURL {
                AsyncImage(url: signedURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        initials
                    case .empty:
                        ProgressView()
                    @unknown default:
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        .task(id: path) {
            guard let path, !path.isEmpty else {
                signedURL = nil
                return
            }
            signedURL = await store.signedURL(bucket: "avatars", path: path)
        }
        .accessibilityLabel(displayName.isEmpty ? "Аватар" : "Аватар \(displayName)")
    }

    private var initials: some View {
        Text(initialText)
            .font(.system(size: max(12, size * 0.36), weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
    }

    private var initialText: String {
        let source = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.first.map { String($0).uppercased() } ?? "V"
    }
}

extension String {
    var voiceDate: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: self) { return date }
        return ISO8601DateFormatter().date(from: self)
    }

    var voiceShortTime: String {
        guard let date = voiceDate else { return self }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    var voiceListTime: String {
        guard let date = voiceDate else { return self }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if Calendar.current.isDateInToday(date) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }
}

extension UIImage {
    func voiceJPEGData(maxDimension: CGFloat = 1600, compression: CGFloat = 0.82) -> Data? {
        let maxSide = max(size.width, size.height)
        guard maxSide > 0 else { return jpegData(compressionQuality: compression) }
        guard maxSide > maxDimension else { return jpegData(compressionQuality: compression) }

        let scale = maxDimension / maxSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let image = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return image.jpegData(compressionQuality: compression)
    }
}
