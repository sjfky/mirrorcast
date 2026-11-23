import Foundation

/// 轻量日志。走 stderr，Xcode 控制台能看到，不引 os.log 是为了让
/// extension target 与 Linux 单测都能用同一份实现。
func NSSLog(_ message: String) {
    if ProcessInfo.processInfo.environment["MIRRORCAST_QUIET"] == nil {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
