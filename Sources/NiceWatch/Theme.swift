import SwiftUI

/// Spectrum 2 色彩角色。原生系统字体兼顾中文、拉丁文字与 macOS 可读性。
struct SpectrumPalette {
    let base: Color
    let surface: Color
    let surfaceSecondary: Color
    let border: Color
    let text: Color
    let subtext: Color
    let accent: Color
    let accentText: Color
    let accentSoft: Color
    let selection: Color
    let onSelection: Color
    let neutral: Color
    let neutralHover: Color
    let success: Color
    let warning: Color
    let danger: Color

    static func of(_ scheme: ColorScheme) -> SpectrumPalette {
        if scheme == .dark {
            return SpectrumPalette(
                base: Color(hex: 0x111111), surface: Color(hex: 0x1E1E1E),
                surfaceSecondary: Color(hex: 0x262626), border: Color(hex: 0x666666),
                text: Color(hex: 0xF2F2F2), subtext: Color(hex: 0xADADAD),
                accent: Color(hex: 0x3B63FB), accentText: Color(hex: 0x7B9AFF), accentSoft: Color(hex: 0x272D50),
                selection: Color(hex: 0xF2F2F2), onSelection: Color(hex: 0x111111),
                neutral: Color(hex: 0x333333), neutralHover: Color(hex: 0x444444),
                success: Color(hex: 0x2FBF86), warning: Color(hex: 0xFF9E3D),
                danger: Color(hex: 0xFF6B5B))
        }
        return SpectrumPalette(
            base: Color(hex: 0xF8F8F8), surface: .white,
            surfaceSecondary: Color(hex: 0xF1F1F1), border: Color(hex: 0x8F8F8F),
            text: Color(hex: 0x222222), subtext: Color(hex: 0x636363),
            accent: Color(hex: 0x3B63FB), accentText: Color(hex: 0x3B63FB), accentSoft: Color(hex: 0xEDEEFF),
            selection: Color(hex: 0x292929), onSelection: .white,
            neutral: Color(hex: 0xE9E9E9), neutralHover: Color(hex: 0xDCDCDC),
            success: Color(hex: 0x007A4D), warning: Color(hex: 0xB95300),
            danger: Color(hex: 0xD31510))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: 1)
    }
}

enum Spectrum {
    static let radius: CGFloat = 16
    static let smallRadius: CGFloat = 8
}

private struct SpectrumSurface: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(SpectrumPalette.of(scheme).surface)
                .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.08),
                        radius: 3, x: 0, y: 1)
        }
    }
}

private struct SpectrumInput: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        let p = SpectrumPalette.of(scheme)
        content
            .focused($focused)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(p.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focused ? p.selection : (hovering ? p.subtext : p.border), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                        .stroke(p.accent, lineWidth: 2)
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}

extension View {
    func spectrumSurface(radius: CGFloat = Spectrum.radius) -> some View {
        modifier(SpectrumSurface(radius: radius))
    }
    func spectrumInput(radius: CGFloat = Spectrum.smallRadius) -> some View {
        modifier(SpectrumInput(radius: radius))
    }
}

struct SpectrumButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, danger, destructive }
    var kind: Kind = .normal
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        SpectrumButtonBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct SpectrumButtonBody: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var focused
        @State private var hovering = false

        var body: some View {
            let p = SpectrumPalette.of(scheme)
            configuration.label
                .font(.system(size: compact ? 12 : 14, weight: .bold))
                .foregroundStyle((kind == .prominent || kind == .destructive) ? .white : (kind == .danger ? p.danger : p.text))
                .lineLimit(1)
                .padding(.horizontal, compact ? 16 : 22)
                .frame(height: compact ? 34 : 42)
                .frame(maxWidth: kind == .prominent && !compact ? .infinity : nil)
                .background(background(p), in: Capsule())
                .overlay {
                    if focused {
                        Capsule().stroke(p.accent, lineWidth: 2).padding(-4)
                    }
                }
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hovering)
                .onHover { hovering = $0 }
        }

        private func background(_ p: SpectrumPalette) -> Color {
            if kind == .destructive {
                if hovering || configuration.isPressed { return Color(hex: 0xAD0E0B) }
                return scheme == .dark ? Color(hex: 0xB82019) : p.danger
            }
            if kind == .prominent {
                if configuration.isPressed { return Color(hex: 0x1E3FCC) }
                return hovering ? Color(hex: 0x274DEA) : p.accent
            }
            return hovering || configuration.isPressed ? p.neutralHover : p.neutral
        }
    }
}

extension ButtonStyle where Self == SpectrumButtonStyle {
    static var spectrum: SpectrumButtonStyle { SpectrumButtonStyle() }
    static var spectrumProminent: SpectrumButtonStyle { SpectrumButtonStyle(kind: .prominent) }
    static var spectrumDanger: SpectrumButtonStyle { SpectrumButtonStyle(kind: .danger) }
    static func spectrumCompact(_ kind: SpectrumButtonStyle.Kind = .normal) -> SpectrumButtonStyle {
        SpectrumButtonStyle(kind: kind, compact: true)
    }
}

/// 实心选中轨道即使在窗口未激活时也可辨认，按钮保留原生键盘焦点。
struct SpectrumToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SpectrumSwitch(configuration: configuration)
    }

    private struct SpectrumSwitch: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        var body: some View {
            let p = SpectrumPalette.of(scheme)
            HStack {
                configuration.label
                    .font(.system(size: 13)).foregroundStyle(p.text)
                Spacer(minLength: 12)
                Button { configuration.isOn.toggle() } label: {
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule().fill(configuration.isOn ? p.selection : p.neutral)
                        Capsule().strokeBorder(configuration.isOn ? p.selection : p.border, lineWidth: 1.5)
                        Circle().fill(configuration.isOn ? p.onSelection : p.subtext)
                            .frame(width: 16, height: 16).padding(3)
                    }
                    .frame(width: 40, height: 22)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .overlay {
                        if focused { Capsule().stroke(p.accent, lineWidth: 2).padding(-3) }
                    }
                }
                .buttonStyle(.plain)
                .opacity(enabled ? 1 : 0.45)
                .accessibilityRepresentation {
                    Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
                }
            }
        }
    }
}

struct SpectrumCard<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = Spectrum.radius
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .spectrumSurface(radius: radius)
    }
}

struct SpectrumSectionTitle: View {
    let title: String
    var subtitle: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(p.text)
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(p.subtext)
            }
        }
    }
}

struct SpectrumField<Content: View>: View {
    var radius: CGFloat = Spectrum.smallRadius
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content.textFieldStyle(.plain)
            .foregroundStyle(SpectrumPalette.of(scheme).text)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .spectrumInput(radius: radius)
    }
}

struct SpectrumTag: View {
    let text: String
    var icon: String?
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        let color = tint ?? p.subtext
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(scheme == .dark ? 0.12 : 0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SpectrumSegmented<T: Hashable>: View {
    let options: [(value: T, title: String, icon: String)]
    @Binding var selection: T
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Label(option.title, systemImage: option.icon)
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .frame(maxWidth: .infinity)
                        .contentShape(Capsule())
                }
                .buttonStyle(SpectrumTabStyle(active: option.value == selection))
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .padding(5)
        .background(p.neutral, in: Capsule())
    }
}

private struct SpectrumTabStyle: ButtonStyle {
    let active: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let p = SpectrumPalette.of(scheme)
        configuration.label
            .foregroundStyle(active ? p.onSelection : p.text)
            .background(active ? p.selection : (hovering ? p.neutralHover : .clear), in: Capsule())
            .overlay {
                if focused { Capsule().stroke(p.accent, lineWidth: 2).padding(-2) }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovering = $0 }
    }
}

struct SpectrumBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { SpectrumPalette.of(scheme).base.ignoresSafeArea() }
}

/// 原生 Slider 支持方向键、VoiceOver 和禁用状态，绑定仍按既定 step 吸附。
struct SpectrumSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
               in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
            .tint(SpectrumPalette.of(scheme).accent)
            .accessibilityLabel("检查间隔")
            .accessibilityValue(Settings.intervalLabel(value))
    }
}
