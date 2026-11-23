import Foundation

/// 加锁执行一段闭包。
/// 故意不叫 withLock —— 新版 SDK 的 NSLocking 自己会带同名方法，
/// 重名会在某些 Xcode 版本上报 redeclaration。
extension NSLock {
    func guarding<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
