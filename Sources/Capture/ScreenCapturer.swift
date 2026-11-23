import Foundation
import CoreMedia
import CoreVideo
import ReplayKit
import UIKit

// MARK: - App 内采集（只能拍到本 App 自己的画面）

/// Apple 的硬限制：`RPScreenRecorder.startCapture` 只覆盖调用方 App 的内容。
/// 想拍别的 App / 系统界面必须走录屏扩展，用 SystemBroadcastPicker 由用户手动开启。
@MainActor
final class InAppCapturer: NSObject, @unchecked Sendable {
    private let encoder = FrameEncoder()
    private let bus: FrameBus
    private(set) var isCapturing = false

    /// 需要按界面方向改这里，见上面的 TODO
    var rotation: CGImagePropertyOrientation = .up

    init(bus: FrameBus) {
        self.bus = bus
        super.init()
    }

    var recorderAvailable: Bool { RPScreenRecorder.shared().isAvailable }

    func start() {
        let recorder = RPScreenRecorder.shared()
        guard !isCapturing, recorder.isAvailable else { return }
        // 静音采集：本 App 的画面镜像不需要收声，避免和播放中的音频抢路由
        recorder.isMicrophoneEnabled = false
        // 先取成局部常量：handler 在采集队列上跑，直接读 @MainActor 属性是数据竞争
        let rotationAtStart = rotation
        let bus = self.bus
        let encoder = self.encoder
        recorder.startCapture(handler: { sampleBuffer, type, error in
            guard error == nil, type == .video,
                  let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            // 旋转：ReplayKit 给的是显示原生方向的帧，横竖屏切换时需要在编码前转正。
            // 这里刻意用固定 .up —— 从 sample buffer attachment 里挖 DisplayTransform
            // 不是公开 API，写进代码会在别的 iOS 版本上静默错位。
            // TODO(旋转): App 侧可用 windowScene.interfaceOrientation 更新 rotation；
            // 扩展侧没有可靠的界面方向来源，只能在收到帧后按像素宽高比反推。
            encoder.encodeAsync(buffer, orientation: rotationAtStart) { jpeg in
                if let jpeg { bus.publish(jpeg) }
            }
        }) { [weak self] error in
            Task { @MainActor in
                self?.isCapturing = (error == nil)
            }
        }
    }

    func stop() {
        guard isCapturing else { return }
        RPScreenRecorder.shared().stopCapture { _ in }
        isCapturing = false
    }
}
