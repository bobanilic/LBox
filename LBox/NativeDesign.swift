import SwiftUI

// The existing preference keys remain owned by their original settings.
enum LBoxAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private struct LBoxSettingsActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openLBoxSettings: () -> Void {
        get { self[LBoxSettingsActionKey.self] }
        set { self[LBoxSettingsActionKey.self] = newValue }
    }
}

struct LBoxSettingsButton: View {
    @Environment(\.openLBoxSettings) private var openSettings
    var body: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }
}

struct LBoxCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
