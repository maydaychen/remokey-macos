import Foundation
import CoreGraphics

/// 宏步骤执行原语。生产实现 LiveMacroPrimitives 真正合成事件；
/// 自检注入假实现记录调用序列（纯逻辑单测）。
protocol MacroPrimitives {
    func perform(_ action: Action)
    func typeText(_ text: String)
    func wait(ms: Int)
}

/// 每次执行独立持有取消状态；取消会唤醒长延时，不能同步等待主线程上的动作。
final class MacroCancellation: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false

    var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    func cancel() {
        condition.lock(); defer { condition.unlock() }
        cancelled = true
        condition.broadcast()
    }

    func wait(ms: Int) {
        guard ms > 0 else { return }
        let deadline = Date().addingTimeInterval(Double(min(ms, 60_000)) / 1000)
        condition.lock(); defer { condition.unlock() }
        while !cancelled && Date() < deadline { _ = condition.wait(until: deadline) }
    }
}

/// 宏执行器（DESIGN §3.2 macro）：
///   - 后台串行 queue 顺序执行 steps（action / delay_ms / text）；
///   - 单步之间默认 20ms 间隔（显式 delay 步骤额外累加）；
///   - 防重入：宏执行中再触发宏 → 忽略并 log；
///   - 嵌套限深：宏里嵌宏最多 1 层，再深忽略并 log（嵌套宏内联执行，不走防重入闸门）。
final class MacroEngine: @unchecked Sendable {
    static let shared = MacroEngine()

    static let interStepMs = 20
    static let maxDepth = 1

    private let q = DispatchQueue(label: "com.miremote.macro")
    private let lock = NSLock()
    private var running = false
    private var cancellation: MacroCancellation?

    /// 是否有宏在执行中（--run-action 等待宏完成再退出用）。
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 触发一段宏（异步，不阻塞调用方）。执行中重入直接忽略。
    func run(_ steps: [MacroStep], runner: ActionRunning) {
        lock.lock()
        if running {
            lock.unlock()
            NSLog("[Macro] 已有宏在执行，忽略本次触发")
            return
        }
        running = true
        let token = MacroCancellation()
        cancellation = token
        lock.unlock()
        q.async { [weak self] in
            MacroEngine.execute(steps, primitives: LiveMacroPrimitives(runner: runner, cancellation: token),
                                depth: 0, isCancelled: { token.isCancelled })
            guard let self else { return }
            self.lock.lock()
            self.running = false
            self.cancellation = nil
            self.lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        let token = cancellation
        lock.unlock()
        token?.cancel()
    }

    static func textChunks(_ text: String, cancellation: MacroCancellation,
                           send: ([UInt16]) -> Void) {
        let utf16 = Array(text.utf16)
        for start in stride(from: 0, to: utf16.count, by: 20) {
            guard !cancellation.isCancelled else { return }
            send(Array(utf16[start..<min(start + 20, utf16.count)]))
            if start + 20 < utf16.count { cancellation.wait(ms: 8) }
        }
    }

    /// 纯逻辑：顺序执行步骤（步骤间隔/嵌套限深都在这里，可注入假 primitives 单测）。
    static func execute(_ steps: [MacroStep], primitives: MacroPrimitives, depth: Int,
                        isCancelled: () -> Bool = { false }) {
        for (i, step) in steps.enumerated() {
            guard !isCancelled() else { return }
            if i > 0 { primitives.wait(ms: interStepMs) }
            guard !isCancelled() else { return }
            switch step {
            case .delay(let ms):
                primitives.wait(ms: ms)
            case .text(let s):
                primitives.typeText(s)
            case .action(.macro(let inner)):
                if depth >= maxDepth {
                    NSLog("[Macro] 嵌套宏超过 %d 层，忽略", maxDepth)
                } else {
                    execute(inner, primitives: primitives, depth: depth + 1, isCancelled: isCancelled)
                }
            case .action(let a):
                primitives.perform(a)
            }
        }
    }
}

/// 生产原语：action 回主线程交给 ActionRunner；text 用 keyboardSetUnicodeString 分段发。
private struct LiveMacroPrimitives: MacroPrimitives {
    let runner: ActionRunning
    let cancellation: MacroCancellation

    func perform(_ action: Action) {
        // MappingEngine 契约是主线程调 run；宏在后台 queue，回主线程保持一致。
        DispatchQueue.main.sync {
            guard !cancellation.isCancelled else { return }
            runner.run(action)
        }
    }

    func typeText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        MacroEngine.textChunks(text, cancellation: cancellation) { chunk in
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
            }
            // 和暂停/停止的主线程路径顺序执行，每段发送前再次检查取消。
            DispatchQueue.main.sync {
                guard !cancellation.isCancelled else { return }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    func wait(ms: Int) {
        // 解码层已把 delay 限制在 0...60_000；这里仍做饱和转换兜底（防负数/
        // 乘法溢出 trap——任意来源的 Action 不能让整个进程崩溃）。
        cancellation.wait(ms: ms)
    }
}
