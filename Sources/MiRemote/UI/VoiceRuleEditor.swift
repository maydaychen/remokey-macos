import SwiftUI

/// 套用仅修改遥键配置；第三方工具仍须使用对应的快捷键设置。
enum VoiceToolPreset: String, CaseIterable {
    case bageshuo, typeless, doubao

    var title: String {
        switch self {
        case .bageshuo: return "网易叭哥说"
        case .typeless: return "Typeless"
        case .doubao: return "豆包输入法（右 Option 按住说话）"
        }
    }

    var rule: VoiceTriggerRule {
        switch self {
        case .bageshuo, .typeless:
            return VoiceTriggerRule(presetID: rawValue, keyName: "fn", mode: "tap", imeBundlePrefix: nil)
        case .doubao:
            return VoiceTriggerRule(presetID: rawValue, keyName: "right_option", mode: "hold",
                                    imeBundlePrefix: "com.bytedance.inputmethod")
        }
    }

    var help: String {
        switch self {
        case .bageshuo:
            return "使用 Fn 单击开始、再次单击结束的兼容配置。请确认叭哥说也使用该快捷键和方式。"
        case .typeless:
            return "按 Typeless 的默认听写配置发送 Fn：单击开始，再次单击结束。若已修改 Typeless 快捷键，可在高级设置中同步。"
        case .doubao:
            return "自动切换豆包输入法，发送右 Option 按住说话。请先在豆包中选择同样的按键和触发方式。"
        }
    }

    static func selected(for rule: VoiceTriggerRule) -> VoiceToolPreset? {
        guard let id = rule.presetID, let preset = Self(rawValue: id), preset.rule == rule else { return nil }
        return preset
    }
}

@MainActor
struct VoiceRuleEditor: View {
    @EnvironmentObject var model: AppModel
    let profile: String

    private var rule: VoiceTriggerRule { model.voiceRule(for: profile) }
    private var inheritsGlobal: Bool { profile != "global" && !model.hasCustomVoiceRule(for: profile) }
    private let keys = ["fn", "right_option", "left_option", "f13", "f5", "right_cmd",
                        "left_cmd", "right_ctrl", "left_ctrl", "right_shift", "left_shift"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if profile != "global" {
                Text(inheritsGlobal ? "正在继承全局语音设置。选择工具或修改高级设置后，仅对当前场景生效。"
                     : "此场景使用独立语音设置。")
                    .font(.callout).foregroundStyle(.secondary)
                if !inheritsGlobal {
                    Button("恢复继承全局") { model.resetVoiceRuleToGlobal(for: profile) }
                }
            }
            Picker("语音工具", selection: presetBinding) {
                Text("自定义（保留当前配置）").tag("custom")
                ForEach(VoiceToolPreset.allCases, id: \.rawValue) { preset in
                    Text(preset.title).tag(preset.rawValue)
                }
            }
            Text(VoiceToolPreset.selected(for: rule)?.help
                 ?? "当前使用自定义配置，可展开高级设置查看。选择工具后，会自动填入遥键的触发按键、触发方式及输入法切换设置。")
                .font(.callout).foregroundStyle(.secondary)
            Text("当前配置：\(rule.keyName) · \(modeName(rule.mode))")
                .font(.callout)
            DisclosureGroup("高级设置") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("触发按键", selection: keyBinding) {
                        ForEach(keys, id: \.self) { Text($0).tag($0) }
                        if !keys.contains(rule.keyName) { Text(rule.keyName).tag(rule.keyName) }
                    }
                    Picker("触发方式", selection: modeBinding) {
                        Text("按住说话").tag("hold")
                        Text("单击开始／再击结束").tag("tap")
                        Text("双击开始／单击结束").tag("double")
                    }
                    Toggle("自动切换到豆包输入法", isOn: imeBinding)
                }
                .padding(.top, 8)
            }
            Text("套用后自动保存到遥键，不会修改第三方工具的设置。遥控器仍按住语音键说话；遥键负责转换成目标工具的开始和结束动作。")
                .font(.footnote).foregroundStyle(.secondary)
            if profile == "global" {
                Text("默认用于所有 App；需要例外时，在「场景配置 → 对应 App → 语音设置」中修改。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func modeName(_ mode: String) -> String {
        switch mode {
        case "hold": return "按住说话"
        case "tap": return "单击开始／再击结束"
        case "double": return "双击开始／单击结束"
        default: return mode
        }
    }

    private var presetBinding: Binding<String> {
        Binding(get: { VoiceToolPreset.selected(for: rule)?.rawValue ?? "custom" }, set: { value in
            model.updateVoiceRule(for: profile) { current in
                if let preset = VoiceToolPreset(rawValue: value) { current = preset.rule }
                else { current.presetID = nil }
            }
        })
    }
    private var keyBinding: Binding<String> {
        Binding(get: { rule.keyName }, set: { value in
            model.updateVoiceRule(for: profile) { $0.keyName = value; $0.presetID = nil }
        })
    }
    private var modeBinding: Binding<String> {
        Binding(get: { rule.mode }, set: { value in
            model.updateVoiceRule(for: profile) { $0.mode = value; $0.presetID = nil }
        })
    }
    private var imeBinding: Binding<Bool> {
        Binding(get: { rule.imeBundlePrefix != nil }, set: { value in
            model.updateVoiceRule(for: profile) {
                $0.imeBundlePrefix = value ? "com.bytedance.inputmethod" : nil
                $0.presetID = nil
            }
        })
    }
}
