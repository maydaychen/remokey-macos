import Foundation

enum MappingEditingSelfTest {
    private final class Runner: ActionRunning {
        var actions: [Action] = []
        func run(_ action: Action) { actions.append(action) }
    }

    static func run() -> Bool {
        var passed = true
        func check(_ value: Bool, _ message: String) {
            if !value { passed = false; print("FAIL  映射编辑：\(message)") }
        }
        var config = MappingConfig()
        let primary = Action.system("mute")
        config.profiles = ["global": [
            "tv": KeyBinding(tap: primary, double: .system("play_pause")),
            "back": KeyBinding(tap: primary, hold: primary, double: primary),
            "up": KeyBinding(tap: primary), "ok": KeyBinding(tap: primary),
        ], "example": ["tv": KeyBinding(double: Action.none)]]
        check(BindingResolver.merged(config, profile: "example", key: .tv)?.tap == primary,
              "空槽位继承全局")
        config.profiles["example"]?["tv"]?.tap = Action.none
        check(BindingResolver.merged(config, profile: "example", key: .tv)?.tap == Action.none,
              "显式 none 禁用继承")
        let encoded = try? JSONEncoder().encode(config)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(MappingConfig.self, from: $0) }
        check(decoded?.profiles["example"]?["tv"]?.tap == Action.none, "禁用持久化往返")
        config.profiles["example"]?["tv"]?.tap = nil
        let runner = Runner()
        var timers: [() -> Void] = []
        let engine = MappingEngine(config: config, runner: runner, delegate: nil,
                                   dispatch: { $0() }, scheduleAfter: { _, task in timers.append(task) })
        engine.setActiveProfile("example")
        func event(_ key: RemoteKey, _ down: Bool) -> ButtonEvent {
            ButtonEvent(key: key, isDown: down, timeNs: 0)
        }
        func tap(_ key: RemoteKey) { engine.handle(event(key, true)); engine.handle(event(key, false)) }
        tap(.tv)
        check(runner.actions == [primary], "禁用 double 后短按立即执行，不等待窗口")
        for key in [RemoteKey.up, .back, .ok] {
            runner.actions = []
            tap(key)
            check(runner.actions == [BindingResolver.effective(config, profile: "example", key: key).tap!],
                  "\(key) 速查与实际基础态一致")
        }
        config.profiles["example"]?["ok"] = KeyBinding(tap: .keyStroke(key: "return", mods: ["left_cmd"]))
        engine.setConfig(config)
        runner.actions = []
        tap(.ok)
        check(runner.actions == [.keyStroke(key: "return", mods: ["left_cmd"])], "保留 App OK 发送覆盖")

        let gate = KeyLearningGate.shared
        defer { gate.setActive(false) }
        runner.actions = []
        engine.handle(event(.tv, true)) // 开窗前存在长按定时器
        check(gate.setActive(true), "可进入识别")
        engine.resetInputState(reason: "识别测试")
        for key in RemoteKey.allCases {
            check(gate.captures(key), "识别捕获 \(key)")
            check(gate.consume(event(key, true)), "按下被消费")
            engine.handle(event(key, true)) // 已排队事件也不得执行
            check(gate.consume(event(key, false)), "松开被消费")
        }
        timers.forEach { $0() }
        check(runner.actions.isEmpty, "识别期间无动作，开窗前定时器失效")
        check(!gate.beginVoice(), "识别期间拒绝语音会话")
        _ = gate.consume(event(.power, true))
        engine.resetInputState(reason: "结束识别测试")
        gate.setActive(false)
        check(gate.captures(.power) && gate.consume(event(.power, true)), "关窗后仍吞掉未松开的重复按下")
        check(gate.consume(event(.power, false)) && !gate.captures(.power), "松开被吞且解除捕获")
        check(!gate.consume(event(.tv, true)), "退出后新按压恢复")
        tap(.tv)
        check(runner.actions == [primary], "退出后正常短按只执行一次")
        check(gate.beginVoice() && !gate.setActive(true), "语音会话与识别互斥")
        gate.endVoice()
        check(gate.setActive(true), "语音结束可进入识别")
        gate.setActive(false)

        check(MainActor.assumeIsolated { saveFailureCheck() }, "保存失败回滚、重试和放弃")
        check(MainActor.assumeIsolated { UIOptimizationSelfTest.run() }, "健康提示、配置导入恢复与电平节流")
        return passed
    }

    @MainActor private static func saveFailureCheck() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miremote-edit-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 目录尚不存在：确定性触发失败，不依赖当前用户是否具备 root 权限。
        let model = AppModel(configURL: url)
        let original = model.binding(for: .tv).tap
        model.updateBinding(for: .tv) { $0.tap = .system("mute") }
        guard model.configSaveError != nil, model.savedTick == 0,
              model.binding(for: .tv).tap == original else { return false }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return false }
        model.retryConfigSave()
        guard model.configSaveError == nil, model.savedTick == 1,
              ConfigStore.load(from: url)?.profiles["global"]?["tv"]?.tap == .system("mute") else { return false }
        try? FileManager.default.removeItem(at: dir)
        model.updateBinding(for: .tv) { $0.tap = Action.none }
        guard model.binding(for: .tv).tap == .system("mute"), model.savedTick == 1 else { return false }
        model.discardPendingConfig()
        model.retryConfigSave()
        return model.configSaveError == nil && model.savedTick == 1
    }
}
