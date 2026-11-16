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
            return "将删除全部时间线和测试记录，保留登录、Bark key、设置与监控名单。监控将继续，仅推送清除后的新投稿。此操作无法撤销。"
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
                Button(action.confirmLabel, role: .destructive, action: onConfirm)
                    .buttonStyle(.spectrumCompact(.destructive))
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 440, alignment: .leading)
        .spectrumSurface(radius: 24)
        .padding(16)
        .background(p.base)
        .interactiveDismissDisabled()
    }
}
