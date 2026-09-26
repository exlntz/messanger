import SwiftUI
import UIKit

struct VoiceBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)

            VOICEGradient()
                .opacity(reduceTransparency ? 0.12 : 0.2)

            RadialGradient(
                colors: [
                    .white.opacity(reduceTransparency ? 0.06 : 0.16),
                    .clear
                ],
                center: .topLeading,
                startRadius: 24,
                endRadius: 320
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct VOICEGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.95),
                Color.purple.opacity(0.75)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct VoiceGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay(border)
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(border)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(border)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var border: some View {
        shape
            .stroke(.white.opacity(reduceTransparency ? 0.08 : 0.18), lineWidth: 1)
    }
}

extension View {
    func voiceGlass(cornerRadius: CGFloat = 24) -> some View {
        modifier(VoiceGlassModifier(cornerRadius: cornerRadius))
    }

    func voiceCard(cornerRadius: CGFloat = 24) -> some View {
        self
            .padding(16)
            .voiceGlass(cornerRadius: cornerRadius)
    }

    func voiceRowCard(cornerRadius: CGFloat = 24, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .voiceGlass(cornerRadius: cornerRadius)
    }
}

enum VoiceAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "Системная"
        case .light:
            "Светлая"
        case .dark:
            "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct VOICEPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
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
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
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
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.9),
                            Color.purple.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

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
                            .tint(.white)
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
            .foregroundStyle(.white)
    }

    private var initialText: String {
        let source = displayName.voiceTrimmed
        return source.first.map { String($0).uppercased() } ?? "V"
    }
}

extension String {
    var voiceTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var voiceDate: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: self) {
            return date
        }
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

    var voiceFullTimestamp: String {
        guard let date = voiceDate else { return self }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension UIImage {
    func voiceJPEGData(maxDimension: CGFloat = 1600, compression: CGFloat = 0.82) -> Data? {
        let maxSide = max(size.width, size.height)
        guard maxSide > 0 else {
            return jpegData(compressionQuality: compression)
        }
        guard maxSide > maxDimension else {
            return jpegData(compressionQuality: compression)
        }

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
