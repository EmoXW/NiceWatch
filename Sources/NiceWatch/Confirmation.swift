import SwiftUI

/// 全部破坏性操作共用同一套 Spectrum 2 确认面板。
enum ConfirmationAction: Identifiable {
    case removeUP(MonitoredUP)
    case clearAllRecords

    var id: String {
        switch self {
        case .removeUP(let up): return "remove-\(up.mid)"
        case .clearAllRecords: return "clear-all"
        }
    }

    var title: String {
        switch self {
        case .removeUP: return "删除这条监控？"
        case .clearAllRecords: return "清除所有记录？"
        }
    }

    var message: String {
        switch self {
        case .removeUP(let up):
            return "将停止监控「\(up.name)」，不再为其推送新投稿。已有记录会保留，之后可重新添加。"
        case .clearAllRecords:
            return "将删除全部通知记录和测试记录，保留登录、Bark key、设置与监控名单。监控将继续，旧内容不再补推。此操作无法撤销。"
        }
    }

    var confirmLabel: String {
        switch self {
        case .removeUP: return "删除监控"
        case .clearAllRecords: return "清除所有记录"
        }
    }
}

struct SpectrumConfirmation: View {
    let action: ConfirmationAction
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.colorScheme) private var scheme
    @FocusState private var cancelFocused: Bool

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(p.danger)
                .frame(width: 48, height: 48)
                .background(p.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(action.title)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(p.text)
                Text(action.message)
                    .font(.system(size: 13))
                    .foregroundStyle(p.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(5)
            }
            HStack(spacing: 12) {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.spectrumCompact())
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button(action.confirmLabel, role: .destructive, action: onConfirm)
                    .buttonStyle(.spectrumCompact(.destructive))
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 440, alignment: .leading)
        .spectrumSurface(radius: 24)
        .accessibilityElement(children: .contain)
        .onAppear { cancelFocused = true }
        .onExitCommand(perform: onCancel)
    }
}

/// 在当前窗口内呈现，保留卡片本身，不再创建带系统外壳的 sheet。
private struct SpectrumConfirmationOverlay: ViewModifier {
    let action: ConfirmationAction?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content
            .disabled(action != nil)
            .allowsHitTesting(action == nil)
            .accessibilityHidden(action != nil)
            .overlay {
                if let action {
                    ZStack {
                        Color.black.opacity(0.32)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { } // 点击遮罩不穿透，也不触发破坏性操作。
                            .accessibilityHidden(true)
                        SpectrumConfirmation(action: action, onCancel: onCancel, onConfirm: onConfirm)
                            .padding(24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
}

extension View {
    func spectrumConfirmation(action: ConfirmationAction?,
                              onCancel: @escaping () -> Void,
                              onConfirm: @escaping () -> Void) -> some View {
        modifier(SpectrumConfirmationOverlay(action: action, onCancel: onCancel, onConfirm: onConfirm))
    }
}
