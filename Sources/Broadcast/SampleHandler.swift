import Foundation
import CoreMedia
import ReplayKit

// MARK: - 整机镜像的采集端（Broadcast Upload Extension 进程）
//
// 这是能拍到"其它 App / 系统界面"的唯一合法途径：用户从系统录屏入口
// （或 App 里的 RPSystemBroadcastPickerView）主动开启广播，系统把整屏采样送到这里。
//
// 只做两条输出，且都不联网：
//   · MJPEG 帧  → App Group 的 frame.jpg   → 主 App 走 multipart 给车机浏览器
//   · H.264+AAC → HLSSegmentWriter         → App Group 的 live/  → 主 App 走 /live/* 给 DLNA
// 本文件只属于 extension target，**不要**加进 App target。

final class SampleHandler: RPBroadcastSampleHandler {

    private let encoder = FrameEncoder()
    private var hls: HLSSegmentWriter?
    private var minInterval: TimeInterval = 1.0 / 12.0
    private var lastWrite = Date.distantPast
    private var lastFrameSize: CGSize = .zero

    /// MJPEG 的目标帧率。车机浏览器普遍扛不住 30fps 的 multipart，
    /// 而且真正瓶颈通常是它的 JPEG 解码器。
    private let targetFPS: Double = 12

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        minInterval = 1.0 / max(1, targetFPS)
        encoder.maxEdge = 1152
        encoder.quality = 0.48
        AppGroupBridge.clear()

        // DLNA 实时镜像是可选的：主 App 不打开开关就不起编码器，省电
        guard AppGroupBridge.liveEnabled else { return }
        guard let scratch = AppGroupBridge.hlsScratchDirectory,
              let publish = AppGroupBridge.hlsDirectory else { return }
        var config = HLSSegmentWriter.Config(width: 1280, height: 720,
                                            videoBitrate: 2_400_000, fps: 30,
                                            segmentSeconds: 2.0, keepsAudio: true,
                                            scratchDirectory: scratch)
        let writer = HLSSegmentWriter(config: config, pump: HLSLivePump(directory: publish))
        // 弱引用：这个闭包会被 writer 长期持有，用 self 会形成
        // SampleHandler ← writer ← 闭包 的循环，广播结束后扩展进程就回收不掉了
        writer.onError = { [weak self] message in
            NSSLog("[广播] \(message)")
            self?.postMessage(message)   // 主 App 的错误面板能读到
        }
        hls = writer
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        // 收尾必须让所有在途采样写完，否则最后一个会话文件会缺一截
        hls?.shutdown {}
        hls = nil
        AppGroupBridge.clear()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            if size != lastFrameSize {
                lastFrameSize = size
                hls?.reconfigure(width: Int(size.width), height: Int(size.height))
            }
            // HLS 这条要每一帧（编码器自己按 GOP/段切），MJPEG 那条按目标帧率丢弃
            hls?.append(sampleBuffer, isVideo: true)

            let now = Date()
            guard now.timeIntervalSince(lastWrite) >= minInterval else { return }
            lastWrite = now
            let encoder = self.encoder
            encoder.encodeAsync(buffer) { jpeg in
                guard let jpeg, !jpeg.isEmpty else { return }
                // 主 App 靠 frame.jpg 的 mtime 判断广播还活着，不需要额外心跳文件
                AppGroupBridge.writeFrame(jpeg)
            }

        case .audio, .audioApp:
            hls?.append(sampleBuffer, isVideo: false)

        @unknown default:
            break
        }
    }

    /// 通过 App Group 传一条状态文本给主 App 显示（扩展没有 UI）
    private func postMessage(_ text: String) {
        guard let url = AppGroupBridge.container?.appendingPathComponent("live.error") else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
