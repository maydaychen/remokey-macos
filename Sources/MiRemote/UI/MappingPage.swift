import SwiftUI

// MARK: - 通用卡片组件（复刻 macOS 系统设置分组外观）

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var icon: String
    var iconColor: Color = .accentColor
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.intra) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, Spacing.rowH)
        .padding(.vertical, Spacing.rowV)
        .frame(minHeight: Spacing.rowMinHeight)
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 44)
    }
}

// MARK: - 映射页

@MainActor
struct MappingPage: View {
    @EnvironmentObject var model: AppModel
    @State private var showKeyLearn = false
    @State private var showSaved = false

    var body: some View {
        SettingsPageLayout {
            header
        } content: {
            VStack(alignment: .leading, spacing: Spacing.section) {
                if model.activeLayer != 0 {
                    Label("已开启：\(modeDisplayName(model.activeLayer))（同一按键现在使用第二功能）", systemImage: "switch.2")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        remotePanel
                        keyEditor
                    }
                    .frame(minWidth: 540, maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: Spacing.section) {
                        remotePanel
                            .frame(maxWidth: .infinity, alignment: .center)
                        keyEditor
                    }
                }
            }
        }
        .sheet(isPresented: $showKeyLearn) { KeyLearnSheet() }
        .onChange(of: model.savedTick) {
            withAnimation(Motion.quickFade) { showSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation(Motion.toastFade) { showSaved = false }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.section) {
            PageHeader(title: "按键映射", subtitle: pageSubtitle)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if showSaved {
                Label("已保存", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Button {
                showKeyLearn = true
            } label: {
                Label("识别按键", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
            .fixedSize()
            .help("按一下遥控器上的键，识别它是哪个键")
            .disabled(model.services?.started != true || model.remoteSuspended || model.degraded
                      || model.voiceActive || model.testToneStatus == .playing)
        }
    }

    private var pageSubtitle: String {
        model.currentProfile == "global"
            ? "点击左侧遥控器上的按键，编辑它的触发动作。改动即时保存并生效。"
            : "正在编辑场景「\(profileDisplayName(model.currentProfile))」的覆盖绑定。"
    }

    private var remotePanel: some View {
        VStack(spacing: Spacing.intra) {
            RemoteDiagram(selected: $model.selectedKey,
                          flashing: model.lastPressedKey,
                          connected: model.connected)
                .frame(width: 190)
            Text("深色圆键为遥控器实体按键位置示意，选中的按键以强调色描边高亮")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 190)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, Spacing.rowH)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.hud))
    }

    // MARK: KeyEditor

    private var keyEditor: some View {
        let key = model.selectedKey
        let binding = model.binding(for: key)
        return VStack(alignment: .leading, spacing: Spacing.section) {
            // 头部
            HStack(spacing: Spacing.intra) {
                Text(KeyDisplay.badge(key))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.badge))
                VStack(alignment: .leading, spacing: 1) {
                    Text(KeyDisplay.name(key)).font(.title3.weight(.semibold))
                    Text(KeyDisplay.usage(key)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .animation(Motion.select, value: key)

            if let protection = BindingResolver.protection(key: key, profile: model.currentProfile, slot: "tap") {
                Label(protection, systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 分组 A：触发方式
            SettingsGroup(title: "触发方式") {
                SettingsRow(icon: "checkmark", iconColor: .blue, title: "短按", subtitle: "松开时立即触发") {
                    BindingActionPicker(key: key, slot: "tap", action: binding.tap) { new in
                        model.updateBinding(for: key) { $0.tap = new }
                    }
                }
                RowDivider()
                SettingsRow(icon: "clock", iconColor: .orange, title: "长按",
                            subtitle: "超过 \(model.config.settings.holdMs) ms 触发") {
                    BindingActionPicker(key: key, slot: "hold", action: binding.hold) { new in
                        model.updateBinding(for: key) { $0.hold = new }
                    }
                }
                RowDivider()
                SettingsRow(icon: "ellipsis", iconColor: .purple, title: "双击",
                            subtitle: model.config.settings.doubleMs > 0
                                ? "\(model.config.settings.doubleMs)ms 窗口内连按两次；配了双击后此键短按需等窗口确认"
                                : "已关闭（在通用页开启）") {
                    BindingActionPicker(key: key, slot: "double", action: binding.double) { new in
                        model.updateBinding(for: key) { $0.double = new }
                    }
                }
            }

            // 分组 B：手势（仅 OK；零同按原则——默认配置无同按手势时不展示此组，
            // 配置里有绑定才显示，高级用户可经 config.json 自配后在此编辑）
            if key == .ok, binding.gesture?.isEmpty == false {
                SettingsGroup(title: "手势（按住 OK + 方向键）") {
                    ForEach(Array(zip(["up", "down", "left", "right"],
                                      ["arrow.up", "arrow.down", "arrow.left", "arrow.right"])), id: \.0) { dir, sym in
                        if dir != "up" { RowDivider() }
                        SettingsRow(icon: sym, iconColor: .teal, title: gestureTitle(dir)) {
                            BindingActionPicker(key: key, slot: "gesture:\(dir)", action: binding.gesture?[dir]) { new in
                                model.updateBinding(for: key) { b in
                                    var g = b.gesture ?? [:]
                                    if let new { g[dir] = new } else { g.removeValue(forKey: dir) }
                                    b.gesture = g.isEmpty ? nil : g
                                }
                            }
                        }
                    }
                }
            }

            // 分组 C：第二功能模式（底层仍沿用 layer 配置格式，UI 不暴露术语）
            DisclosureGroup {
                Text("单击 TV 进出 App 控制模式；基础态受保护的按键可在这里设置第二功能，屏幕角落会显示键位提示。")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                SettingsGroup(title: "模式开启时，这个键执行") {
                    ForEach(1...3, id: \.self) { layer in
                        if layer != 1 { RowDivider() }
                        SettingsRow(icon: "switch.2", iconColor: .blue, title: modeDisplayName(layer)) {
                            BindingActionPicker(key: key, slot: "\(layer)", action: binding.layers?["\(layer)"]) { new in
                                model.updateBinding(for: key) { b in
                                    var l = b.layers ?? [:]
                                    if let new { l["\(layer)"] = new } else { l.removeValue(forKey: "\(layer)") }
                                    b.layers = l.isEmpty ? nil : l
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("第二功能模式（高级）").font(.callout)
            }

            Text("绑定组合键可点击「录制快捷键」。如果不确定当前状态，可再按一下 TV 键退出 App 控制模式。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gestureTitle(_ dir: String) -> String {
        ["up": "上", "down": "下", "left": "左", "right": "右"][dir].map { "OK + \($0)" } ?? dir
    }
}

func profileDisplayName(_ bundleID: String) -> String {
    if bundleID == "global" { return "全局默认（Global）" }
    if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
       let name = running.localizedName, !name.isEmpty {
        return name
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: url.path)
    }
    return profileFallbackName(bundleID)
}

func profileFallbackName(_ bundleID: String) -> String {
    Presets.all.first(where: { $0.bundleID == bundleID })?.displayName ?? bundleID
}

// MARK: - 识别按键 sheet（学习模式：显示下一个按下的遥控键）

@MainActor
struct KeyLearnSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var learned: RemoteKey?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("识别按键").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            if let key = learned {
                VStack(spacing: 6) {
                    Text(KeyDisplay.badge(key))
                        .font(.title.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    Text(KeyDisplay.name(key)).font(.title3.weight(.semibold))
                    Text(KeyDisplay.usage(key)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("再识别一个") { learned = nil }
                    Button("编辑此键") {
                        model.selectedKey = key
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if model.connected || model.services?.started == true {
                ProgressView().controlSize(.small)
                Text("请按一下遥控器上的任意键…")
                    .font(.callout)
                Text("识别期间不执行按键动作或语音输入，松开按键后再退出。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("引擎未运行（预览模式或遥控器未连接），无法识别").font(.callout)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            guard KeyLearningGate.shared.setActive(true) else { dismiss(); return }
            model.services?.tapEngine?.resetPressState()
            model.services?.keyMapper?.engine.resetInputState(reason: "开始识别按键")
            MouseMode.shared.deactivate()
        }
        .onDisappear {
            model.services?.keyMapper?.engine.resetInputState(reason: "结束识别按键")
            KeyLearningGate.shared.setActive(false)
        }
        .onChange(of: model.lastPressedKey) { _, new in
            if let new, learned == nil { learned = new }
        }
    }
}
