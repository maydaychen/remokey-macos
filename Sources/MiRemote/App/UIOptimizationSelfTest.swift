import Foundation

/// 只使用隔离配置目录和合成音频，不触发硬件或导入用户配置。
@MainActor
enum UIOptimizationSelfTest {
    static func run() -> Bool {
        var passed = true
        func check(_ value: Bool, _ message: String) {
            if !value { passed = false; print("FAIL  UI 优化：\(message)") }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remokey-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let model = AppModel(configURL: url)
        let original = model.config
        var imported = original
        imported.profiles["import.example"] = ["tv": KeyBinding(tap: .system("mute"))]
        check(!model.importConfig(imported) && model.importUndoSnapshot == nil,
              "导入保存失败不提供虚假撤销")
        check(model.config.profiles["import.example"] == nil, "失败保持原配置")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return false }
        model.retryConfigSave()
        check(model.importUndoSnapshot != nil && ConfigStore.load(from: url)?.profiles["import.example"] != nil,
              "重试成功落盘且保留撤销")
        model.currentProfile = "import.example"
        try? FileManager.default.removeItem(at: dir)
        check(!model.undoConfigImport() && model.importUndoSnapshot != nil
              && model.config.profiles["import.example"] != nil, "撤销失败保持当前配置和恢复机会")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return false }
        model.retryConfigSave()
        check(model.currentProfile == "global" && model.importUndoSnapshot == nil && ConfigStore.load(from: url)?.profiles["import.example"] == nil,
              "撤销重试恢复原配置")
        check(model.importConfig(imported), "再次导入成功")
        model.updateBinding(for: .tv) { $0.tap = .system("mute") }
        check(model.importUndoSnapshot == nil, "后续编辑不允许过期撤销覆盖新修改")

        model.healthState = .degraded(["遥控已暂停"])
        check(model.healthMessage.contains("遥控已暂停"), "暂停保留具体原因")
        model.healthState = .broken(["辅助功能权限被撤销"])
        check(model.healthMessage.contains("辅助功能权限被撤销"), "权限失败不伪装成通道断开")

        var time: TimeInterval = 0
        let meter = LevelMeterSink(now: { time })
        var levels: [Float] = []
        meter.onLevel = { levels.append($0) }
        meter.streamStarted(sampleRate: 16000)
        for i in 0..<1000 {
            time = Double(i) / 1000
            meter.write([1000, -1000])
        }
        check(levels.count >= 19 && levels.count <= 21, "每秒千批样本仅发布约 20 次电平")
        meter.streamStopped()
        check(levels.last == 0, "结束立即归零")
        meter.streamStarted(sampleRate: 16000)
        meter.write([1000])
        check((levels.last ?? 0) > 0, "新会话首帧立即显示")
        return passed
    }
}
