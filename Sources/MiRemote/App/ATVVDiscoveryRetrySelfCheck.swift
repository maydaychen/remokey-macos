import Foundation

enum ATVVDiscoveryRetrySelfCheck {
    static func run() -> Bool {
        let queue = DispatchQueue(label: "remokey.discovery-retry.test")
        let retry = ATVVDiscoveryRetry(queue: queue, interval: 0.01)
        let found = DispatchSemaphore(value: 0)
        var lookups = 0
        var duplicate = false
        queue.sync {
            // 模拟两次查不到设备，第三次由系统 HID 恢复连接后取回。
            retry.start {
                lookups += 1
                if lookups == 3 {
                    retry.stop()
                    found.signal()
                }
            }
            retry.start { duplicate = true }
        }
        guard found.wait(timeout: .now() + 2) == .success else {
            queue.sync { retry.stop() }
            return false
        }
        let drained = DispatchSemaphore(value: 0)
        queue.asyncAfter(deadline: .now() + 0.05) { drained.signal() }
        guard drained.wait(timeout: .now() + 2) == .success else { return false }
        let first = queue.sync { lookups == 3 && !duplicate }
        let resumed = DispatchSemaphore(value: 0)
        queue.sync {
            // stop 后重启只允许新一代查询；立即取消的闭包不能运行。
            retry.start { duplicate = true }
            retry.stop()
            retry.start {
                lookups += 1
                retry.stop()
                resumed.signal()
            }
        }
        guard resumed.wait(timeout: .now() + 2) == .success else {
            queue.sync { retry.stop() }
            return false
        }
        return queue.sync { first && lookups == 4 && !duplicate }
    }
}
