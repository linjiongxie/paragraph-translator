import SwiftUI

struct TranslationCard: View {
    @ObservedObject var model: TranslationModel
    let onClose: () -> Void
    let onAccess: () -> Void
    let onEdit: () -> Void

    private let accent = Color(red: 0.16, green: 0.36, blue: 0.90)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 23)).foregroundStyle(accent)
                Text("段落翻译").font(.system(size: 18, weight: .semibold))
                Text("Codex").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(accent.opacity(0.08), in: Capsule())
                    .foregroundStyle(accent)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭 · Esc")
            }
            .padding(.bottom, 22)

            if !model.captureWarning.isEmpty && model.phase != .ready {
                Text(model.captureWarning).font(.system(size: 11)).foregroundStyle(.orange)
                    .padding(.bottom, 10)
            }

            if model.phase == .ready {
                editor
            } else {
                HStack {
                    Text("英文原文").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新输入", action: onEdit).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                }
                ScrollView {
                    FormattedPassageView(text: model.source.isEmpty ? "尚未取得选中文字" : model.source, fontSize: 13)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: 92).padding(.top, 8)

                Divider().padding(.vertical, 18)
                result
            }

            Spacer(minLength: 16)
            if !model.accessibilityGranted {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised").font(.system(size: 11))
                    Text("跨应用读取选中文字需要辅助功能授权").font(.system(size: 11))
                    Spacer(minLength: 0)
                    Button("去授权", action: onAccess).buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary).padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 14)
            }
            Divider().padding(.bottom, 14)
            HStack {
                Text(model.shortcutMessage).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if model.phase == .translated {
                    Button(action: { model.copyTranslation() }) {
                        Label(model.copied ? "已复制" : "复制译文", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.regular)
                } else {
                    Text("Esc 关闭").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .overlay(alignment: .bottomTrailing) {
            WindowResizeHandle()
                .frame(width: 22, height: 22)
                .padding(2)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选一段英文，按下 ⌥⌘T")
                .font(.system(size: 22, weight: .semibold))
            Text("在当前阅读位置查看整段中文，也可以直接粘贴英文。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.source)
                .font(.system(size: 14)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 140)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            HStack {
                Button("粘贴英文") {
                    if let text = NSPasteboard.general.string(forType: .string) { model.source = text }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("翻译为中文") { model.translate(model.source) }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("使用本机 Codex 登录 · 原文会发送至模型")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            if !model.message.isEmpty {
                Text(model.message).font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch model.phase {
        case .translating, .translated:
            if model.phase == .translating && model.translation.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在翻译整段英文…").font(.system(size: 16, weight: .medium))
                    }
                    Text("Codex 正在生成中文译文 · \(Int(model.elapsed)) 秒")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if model.elapsed >= 15 {
                        Text("响应时间受网络和模型负载影响，可按 Esc 取消。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(spacing: 8) {
                    Text("中文译文").font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    if model.phase == .translating { ProgressView().controlSize(.mini) }
                    Spacer()
                    if model.phase == .translating {
                        Text("正在翻译 · \(Int(model.elapsed)) 秒").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if model.elapsed > 0 {
                        Text(String(format: "%.1f 秒", model.elapsed)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.bottom, 10)
                ScrollView {
                    FormattedPassageView(text: model.translation, fontSize: 15)
                }
                .frame(maxHeight: .infinity)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 14) {
                Label("暂时无法翻译", systemImage: "exclamationmark.circle")
                    .font(.system(size: 16, weight: .medium))
                Text(model.message).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !model.source.isEmpty {
                    Button("重试") { model.translate(model.source, captureWarning: model.captureWarning) }.buttonStyle(.bordered)
                }
                Button("输入或粘贴英文", action: onEdit).buttonStyle(.plain).foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .ready:
            EmptyView()
        }
    }
}
