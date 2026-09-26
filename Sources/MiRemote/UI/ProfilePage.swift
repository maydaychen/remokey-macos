import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct ProfilePage: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarItem
    @State private var showAddApp = false
    @State private var showPresets = false
    @State private var detailProfile: ProfileDetailSelection?
    @State private var hoveredProfile: String?

    private var overlayProfiles: [String] {
        Set(model.config.profiles.keys).union(model.config.voiceProfiles?.keys.map { $0 } ?? [])
            .filter { $0 != "global" }.sorted()
    }

    var body: some View {
        SettingsPageLayout {
            PageHeader(title: "场景配置",
                       subtitle: "按前台 App 自动切换按键和语音设置，未单独配置的项目继承全局。")
        } content: {
            VStack(alignment: .leading, spacing: Spacing.section) {
                SettingsGroup(title: "全局") {
                    Button {
                        detailProfile = ProfileDetailSelection(id: "global")
                    } label: {
                        SettingsRow(icon: "globe", title: "全局默认（Global）",
                                    subtitle: "适用于所有未单独配置的 App") {
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }

                SettingsGroup(title: "按 App 覆盖") {
                    if overlayProfiles.isEmpty {
                        Text("暂无 App 专用按键方案。点下方按钮添加，或从预设库一键套用。")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    ForEach(Array(overlayProfiles.enumerated()), id: \.element) { idx, bundle in
                        if idx != 0 { RowDivider() }
                        profileRow(bundle)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        profileActions
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    VStack(alignment: .leading, spacing: 10) {
                        profileActions
                    }
                }
            }
        }
        .sheet(isPresented: $showAddApp) { AddRunningAppSheet() }
        .sheet(isPresented: $showPresets) { PresetLibrarySheet() }
        .sheet(item: $detailProfile) { selected in
            TabView {
                MappingDetailView(config: model.config, profile: selected.id,
                                  onEdit: {
                                      detailProfile = nil
                                      model.currentProfile = selected.id
                                      selection = .mapping
                                  },
                                  onClose: { detailProfile = nil })
                    .tabItem { Text("按键映射") }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(profileDisplayName(selected.id)).font(.title2.bold())
                        Spacer()
                        Button("完成") { detailProfile = nil }
                    }
                    ScrollView {
                        VoiceRuleEditor(profile: selected.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
                .tabItem { Text("语音设置") }
            }
            .frame(width: 900, height: 650)
        }
    }

    @ViewBuilder
    private var profileActions: some View {
        Button {
            showAddApp = true
        } label: {
            Label("从运行中的 App 添加", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)

        Button("导入预设") { showPresets = true }
        Button("导入 JSON 文件") { importJSON() }
        Button("导出 JSON") { exportJSON() }
        if model.importUndoSnapshot != nil {
            Button("撤销配置导入") { model.undoConfigImport() }
        }

        if model.presetUndoSnapshot != nil {
            Button("撤销本次套用") { model.undoPresetApply() }
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func profileRow(_ bundle: String) -> some View {
        let overrides = model.config.profiles[bundle] ?? [:]
        // 整行可点进详情；删除只在 hover 时出现（系统设置语汇：行尾只留 chevron），也可右键删除
        HStack(spacing: Spacing.intra) {
            appIcon(bundle)
            VStack(alignment: .leading, spacing: 1) {
                Text(profileDisplayName(bundle)).font(.body)
                Text((overrides.isEmpty ? "按键继承全局" : "已覆盖 \(overrides.count) 个键")
                     + (model.hasCustomVoiceRule(for: bundle) ? " · 独立语音设置" : " · 语音继承全局"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hoveredProfile == bundle {
                Button {
                    removeProfile(bundle)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary).font(.caption)
                }
                .buttonStyle(.plain)
                .help("删除该 App 专用方案")
                .transition(.opacity)
            }
            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, Spacing.rowH)
        .padding(.vertical, Spacing.rowV)
        .frame(minHeight: Spacing.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { detailProfile = ProfileDetailSelection(id: bundle) }
        .onHover { hovering in
            withAnimation(Motion.select) { hoveredProfile = hovering ? bundle : nil }
        }
        .contextMenu {
            Button("查看详情") { detailProfile = ProfileDetailSelection(id: bundle) }
            Button("删除该 App 专用方案", role: .destructive) { removeProfile(bundle) }
        }
    }

    private func removeProfile(_ bundle: String) {
        model.config.profiles.removeValue(forKey: bundle)
        model.config.voiceProfiles?.removeValue(forKey: bundle)
        if model.currentProfile == bundle { model.currentProfile = "global" }
        model.saveConfig()
    }

    private func appIcon(_ bundle: String) -> some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 24, height: 24)
            } else {
                Text(String(profileDisplayName(bundle).prefix(2)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            }
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择遥键映射配置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try JSONDecoder().decode(MappingConfig.self, from: Data(contentsOf: url))
            guard (1...MappingConfig.currentVersion).contains(imported.version) else {
                throw NSError(domain: "MiRemote", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "不支持配置版本 \(imported.version)，当前最高支持版本 \(MappingConfig.currentVersion)"])
            }
            var candidate = migrateConfigIfNeeded(imported)
            if candidate.profiles["global"] == nil { candidate.profiles["global"] = [:] }
            let preview = NSAlert()
            preview.alertStyle = .warning
            preview.messageText = "替换现有映射配置？"
            let existing = Set(model.config.profiles.keys)
            let incoming = Set(candidate.profiles.keys)
            preview.informativeText = "当前 \(existing.count) 个场景，导入后 \(incoming.count) 个场景。\n替换 \(existing.intersection(incoming).count) 个，新增 \(incoming.subtracting(existing).count) 个，移除 \(existing.subtracting(incoming).count) 个。\n全部按键映射、语音规则和配置参数将被替换。导入后可撤销一次；再次保存配置后撤销失效。"
            preview.addButton(withTitle: "取消")
            preview.addButton(withTitle: "替换配置")
            guard preview.runModal() == .alertSecondButtonReturn else { return }
            model.importConfig(candidate)
        } catch {
            showError(title: "无法导入配置", message: error.localizedDescription)
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "RemoKey-config.json"
        panel.message = "导出当前全部映射与 Profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ConfigStore.save(model.config, to: url) else {
            showError(title: "无法导出配置", message: "请检查目标文件夹权限后重试。")
            return
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private struct ProfileDetailSelection: Identifiable {
    let id: String
}

// MARK: - 从运行中的 App 添加

// 菜单栏型应用使用 .accessory，例如网易叭哥说。只接纳顶层 .app，避免把其
// WebKit Networking / WebContent / GPU 等嵌套辅助进程列成可配置应用。
func isTopLevelApplicationBundle(_ url: URL) -> Bool {
    guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return false }
    var parent = url.deletingLastPathComponent()
    while parent.path != "/" {
        if parent.pathExtension.caseInsensitiveCompare("app") == .orderedSame { return false }
        let next = parent.deletingLastPathComponent()
        if next == parent { break }
        parent = next
    }
    return true
}

func shouldListRunningApplication(
    bundleIdentifier: String?,
    bundleURL: URL?,
    activationPolicy: NSApplication.ActivationPolicy,
    ownBundleIdentifier: String?
) -> Bool {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty,
          bundleIdentifier != ownBundleIdentifier,
          let bundleURL, isTopLevelApplicationBundle(bundleURL) else { return false }
    return activationPolicy == .regular || activationPolicy == .accessory
}

@MainActor
struct AddRunningAppSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var apps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter {
                shouldListRunningApplication(
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL,
                    activationPolicy: $0.activationPolicy,
                    ownBundleIdentifier: Bundle.main.bundleIdentifier)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择要添加专用按键方案的 App").font(.headline)
            List(apps, id: \.processIdentifier) { app in
                Button {
                    guard let bundle = app.bundleIdentifier else { return }
                    if model.config.profiles[bundle] == nil {
                        model.config.profiles[bundle] = [:]
                        guard model.saveConfig() else { return }
                    }
                    model.currentProfile = bundle
                    dismiss()
                } label: {
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(app.localizedName ?? app.bundleIdentifier ?? "?")
                        Spacer()
                        if model.config.profiles[app.bundleIdentifier ?? ""] != nil {
                            Text("已存在").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 360, height: 300)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
            }
        }
        .padding(16)
    }
}

// MARK: - 预设库 sheet（浏览 / 预览改动 / 冲突处理 / 套用）

@MainActor
struct PresetLibrarySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var previewing: String?    // preset.id
    @State private var appliedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预设库").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            if let msg = appliedMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Presets.all, id: \.id) { preset in
                        presetCard(preset)
                    }
                }
            }
            .frame(width: 480, height: 420)
        }
        .padding(16)
    }

    @ViewBuilder
    private func presetCard(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName).font(.headline)
                    if let bundle = preset.bundleID {
                        Text("建议应用到：\(profileDisplayName(bundle))")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("功能模式 · 适用于所有 App").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(previewing == preset.id ? "收起" : "预览") {
                    previewing = previewing == preset.id ? nil : preset.id
                }
                .controlSize(.small)
                Menu("应用") {
                    Button("仅填空位（推荐，保护已有绑定）") { apply(preset, onlyFillEmpty: true) }
                    Button("全部覆盖（预设优先）") { apply(preset, onlyFillEmpty: false) }
                }
                .controlSize(.small)
                .fixedSize()
            }
            Text(preset.note).font(.caption).foregroundStyle(.secondary)
            if previewing == preset.id {
                previewTable(preset)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    /// 改动清单表：键 / 当前绑定 / 预设将改成；冲突行标黄。
    @ViewBuilder
    private func previewTable(_ preset: Preset) -> some View {
        let target = preset.bundleID ?? "global"
        let existing = model.config.profiles[target] ?? [:]
        VStack(spacing: 4) {
            ForEach(preset.bindings.keys.sorted(), id: \.self) { keyName in
                let presetBinding = preset.bindings[keyName]!
                let curBinding = existing[keyName]
                let rows = diffRows(preset: presetBinding, current: curBinding)
                ForEach(rows, id: \.slot) { row in
                    HStack {
                        Text("\(RemoteKey(rawValue: keyName).map(KeyDisplay.name) ?? keyName) · \(row.slot)")
                            .font(.caption)
                            .frame(width: 150, alignment: .leading)
                        Text(row.current ?? "—")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(row.new)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(row.conflict ? Color.yellow.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
            }
        }
        .padding(.top, 4)
    }

    private struct DiffRow { let slot: String; let current: String?; let new: String; let conflict: Bool }

    private func diffRows(preset: KeyBinding, current: KeyBinding?) -> [DiffRow] {
        var rows: [DiffRow] = []
        func add(_ slot: String, _ p: Action?, _ c: Action?) {
            guard let p else { return }
            rows.append(DiffRow(slot: slot,
                                current: c.map { ActionSummary.describe($0) },
                                new: ActionSummary.describe(p),
                                conflict: c != nil && c != p))
        }
        add("短按", preset.tap, current?.tap)
        add("长按", preset.hold, current?.hold)
        add("双击", preset.double, current?.double)
        for (dir, act) in preset.gesture ?? [:] {
            add("手势·\(dir)", act, current?.gesture?[dir])
        }
        for (layer, act) in (preset.layers ?? [:]).sorted(by: { $0.key < $1.key }) {
            add(modeDisplayName(Int(layer) ?? 0), act, current?.layers?[layer])
        }
        return rows
    }

    private func apply(_ preset: Preset, onlyFillEmpty: Bool) {
        model.applyPreset(preset, to: preset.bundleID, onlyFillEmpty: onlyFillEmpty)
        appliedMessage = model.configSaveError == nil
            ? "已套用「\(preset.displayName)」，可在 Profile 页撤销本次套用" : nil
    }
}
