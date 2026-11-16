import SwiftUI

// MARK: - 新拟态配色

/// 新拟态（neumorphism / soft UI）的核心：元素与背景同色，
/// 只靠「左上高光 + 右下阴影」的双向柔和光影来表达凸起与凹陷。
struct NeuPalette {
    let base: Color        // 背景与元素共用的底色
    let light: Color       // 高光
    let dark: Color        // 阴影
    let text: Color
    let subtext: Color
    let accent: Color
    let accentSoft: Color
    let success: Color
    let warning: Color
    let danger: Color

    static func of(_ scheme: ColorScheme) -> NeuPalette {
        if scheme == .dark {
            return NeuPalette(
                base: Color(red: 0.153, green: 0.169, blue: 0.196),        // #272B32
                light: Color.white.opacity(0.075),
                dark: Color.black.opacity(0.62),
                text: Color(white: 0.93),
                subtext: Color(white: 0.60),
                accent: Color(red: 0.47, green: 0.56, blue: 1.00),
                accentSoft: Color(red: 0.47, green: 0.56, blue: 1.00).opacity(0.18),
                success: Color(red: 0.36, green: 0.82, blue: 0.60),
                warning: Color(red: 0.98, green: 0.72, blue: 0.32),
                danger: Color(red: 0.96, green: 0.45, blue: 0.45)
            )
        }
        return NeuPalette(
            base: Color(red: 0.906, green: 0.925, blue: 0.949),            // #E7EC F2
            light: Color.white.opacity(0.95),
            dark: Color(red: 0.596, green: 0.651, blue: 0.749).opacity(0.72),
            text: Color(red: 0.196, green: 0.227, blue: 0.286),
            subtext: Color(red: 0.435, green: 0.482, blue: 0.553),
            accent: Color(red: 0.353, green: 0.435, blue: 0.937),
            accentSoft: Color(red: 0.353, green: 0.435, blue: 0.937).opacity(0.14),
            success: Color(red: 0.184, green: 0.651, blue: 0.427),
            warning: Color(red: 0.851, green: 0.545, blue: 0.129),
            danger: Color(red: 0.831, green: 0.290, blue: 0.290)
        )
    }
}

enum Neu {
    static let radius: CGFloat = 18
    static let smallRadius: CGFloat = 12
    static let shadow: CGFloat = 9
    static let distance: CGFloat = 5
}

// MARK: - 凸起 / 凹陷修饰器

private struct NeuRaised: ViewModifier {
    var radius: CGFloat
    var distance: CGFloat
    var strong: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let p = NeuPalette.of(scheme)
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(p.base)
                    .shadow(color: p.dark, radius: Neu.shadow,
                            x: distance, y: distance)
                    .shadow(color: p.light, radius: Neu.shadow,
                            x: -distance, y: -distance)
            }
            .overlay {
                if strong {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(p.light.opacity(0.7), lineWidth: 0.8)
                }
            }
    }
}

private struct NeuInset: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let p = NeuPalette.of(scheme)
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(p.base)
                    // 上沿压暗 = 凹进去
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [p.dark.opacity(0.55), .clear, .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    // 下沿微亮 = 凹槽底部的反光
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .clear, p.light.opacity(0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(p.dark.opacity(0.25), lineWidth: 0.7)
                }
            }
    }
}

extension View {
    /// 凸起（卡片、按钮静止态）
    func neuRaised(radius: CGFloat = Neu.radius,
                   distance: CGFloat = Neu.distance,
                   strong: Bool = false) -> some View {
        modifier(NeuRaised(radius: radius, distance: distance, strong: strong))
    }

    /// 凹陷（输入框、滑轨、内容区）
    func neuInset(radius: CGFloat = Neu.smallRadius) -> some View {
        modifier(NeuInset(radius: radius))
    }
}

// MARK: - 按钮

struct NeuButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, danger }
    var kind: Kind = .normal
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        NeuButtonBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct NeuButtonBody: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let p = NeuPalette.of(scheme)
            let shape = RoundedRectangle(
                cornerRadius: compact ? Neu.smallRadius : 14,
                style: .continuous
            )

            configuration.label
                .font(.system(size: compact ? 12 : 13,
                              weight: kind == .prominent ? .semibold : .medium))
                .foregroundStyle(foreground(p))
                .lineLimit(1)
                .padding(.horizontal, compact ? 12 : 18)
                .padding(.vertical, compact ? 6 : 10)
                .frame(maxWidth: (kind == .prominent && !compact) ? .infinity : nil)
                .background {
                    if configuration.isPressed {
                        shape.fill(p.base).neuInset(radius: compact ? Neu.smallRadius : 14)
                    } else if kind == .prominent {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [p.accent.opacity(0.92), p.accent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: p.accent.opacity(0.42),
                                    radius: 10, x: 3, y: 5)
                    } else {
                        shape.fill(p.base)
                            .shadow(color: p.dark, radius: hovering ? 9 : 7,
                                    x: 4, y: 4)
                            .shadow(color: p.light, radius: hovering ? 9 : 7,
                                    x: -4, y: -4)
                    }
                }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }

        private func foreground(_ p: NeuPalette) -> Color {
            switch kind {
            case .prominent: return .white
            case .danger: return p.danger
            case .normal: return p.text
            }
        }
    }
}

extension ButtonStyle where Self == NeuButtonStyle {
    static var neu: NeuButtonStyle { NeuButtonStyle() }
    static var neuProminent: NeuButtonStyle { NeuButtonStyle(kind: .prominent) }
    static var neuDanger: NeuButtonStyle { NeuButtonStyle(kind: .danger) }
    static func neuCompact(_ kind: NeuButtonStyle.Kind = .normal) -> NeuButtonStyle {
        NeuButtonStyle(kind: kind, compact: true)
    }
}

// MARK: - 开关

struct NeuToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        NeuToggleBody(configuration: configuration)
    }

    private struct NeuToggleBody: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let p = NeuPalette.of(scheme)
            HStack(spacing: 10) {
                configuration.label
                    .font(.system(size: 13))
                    .foregroundStyle(p.text)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        configuration.$isOn.wrappedValue.toggle()
                    }
                } label: {
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(p.base)
                            .frame(width: 42, height: 24)
                            .neuInset(radius: 12)
                            .overlay {
                                Capsule().strokeBorder(p.dark.opacity(0.45), lineWidth: 0.8)
                            }
                        Circle()
                            .fill(configuration.isOn ? p.accent : p.base)
                            .frame(width: 17, height: 17)
                            .padding(.horizontal, 3.5)
                            .shadow(color: p.dark.opacity(0.7), radius: 2.5, x: 1.5, y: 1.5)
                            .shadow(color: p.light, radius: 2.5, x: -1.5, y: -1.5)
                    }
                    .frame(width: 42, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 常用容器

/// 凸起卡片
struct NeuCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = Neu.radius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neuRaised(radius: radius, strong: true)
    }
}

/// 区块标题
struct NeuSectionTitle: View {
    let title: String
    var subtitle: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = NeuPalette.of(scheme)
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(p.subtext)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.subtext.opacity(0.75))
            }
        }
        .padding(.horizontal, 6)
    }
}

/// 凹陷输入框
struct NeuField<Content: View>: View {
    var radius: CGFloat = Neu.smallRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .neuInset(radius: radius)
    }
}

/// 状态小胶囊
struct NeuTag: View {
    let text: String
    var icon: String?
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = NeuPalette.of(scheme)
        let color = tint ?? p.subtext
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(p.base)
                .shadow(color: p.dark.opacity(0.8), radius: 3, x: 1.5, y: 1.5)
                .shadow(color: p.light, radius: 3, x: -1.5, y: -1.5)
        }
    }
}

/// 新拟态分段控件（替代系统 TabView 的页签）
struct NeuSegmented<T: Hashable>: View {
    let options: [(value: T, title: String, icon: String)]
    @Binding var selection: T
    @Namespace private var ns
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = NeuPalette.of(scheme)
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = option.value
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(option.title)
                            .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                    }
                    .foregroundStyle(active ? p.accent : p.subtext)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(p.base)
                                .neuInset(radius: 11)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .neuRaised(radius: 15)
    }
}

/// 全窗口背景
struct NeuBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        NeuPalette.of(scheme).base.ignoresSafeArea()
    }
}

/// 新拟态滑块：凹陷轨道 + 凸起旋钮，按 step 吸附
struct NeuSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    @Environment(\.colorScheme) private var scheme

    private let knob: CGFloat = 22
    private let trackH: CGFloat = 11

    var body: some View {
        let p = NeuPalette.of(scheme)
        GeometryReader { geo in
            let fullWidth = max(1, geo.size.width)
            let usable = max(1, fullWidth - knob)
            let span = max(1, range.upperBound - range.lowerBound)
            let ratio = Double(value - range.lowerBound) / Double(span)
            let clampedRatio = min(max(ratio, 0), 1)
            let x = usable * CGFloat(clampedRatio)

            ZStack(alignment: .leading) {
                // 轨道：显式给宽度，避免被形状的理想尺寸收缩
                Capsule()
                    .fill(p.dark.opacity(0.34))
                    .overlay {
                        Capsule().strokeBorder(p.dark.opacity(0.5), lineWidth: 0.9)
                    }
                    .frame(width: fullWidth, height: trackH)

                Capsule()
                    .fill(
                        LinearGradient(colors: [p.accent.opacity(0.8), p.accent],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(trackH, x + knob / 2), height: trackH)

                Circle()
                    .fill(p.base)
                    .frame(width: knob, height: knob)
                    .shadow(color: p.dark, radius: 4, x: 2, y: 2)
                    .shadow(color: p.light, radius: 4, x: -2, y: -2)
                    .overlay {
                        Circle().strokeBorder(p.accent.opacity(0.85), lineWidth: 1.6)
                    }
                    .offset(x: x)
            }
            .frame(width: fullWidth, height: knob + 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let r = (g.location.x - knob / 2) / usable
                        let raw = Double(range.lowerBound) + Double(span) * Double(min(max(r, 0), 1))
                        let snapped = (raw / Double(step)).rounded() * Double(step)
                        let clamped = min(Double(range.upperBound),
                                          max(Double(range.lowerBound), snapped))
                        let newValue = Int(clamped)
                        if newValue != value { value = newValue }
                    }
            )
        }
        .frame(height: knob + 4)
    }
}
