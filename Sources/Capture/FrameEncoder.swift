import Foundation
import CoreVideo
import CoreImage
import ImageIO
import UIKit

// MARK: - CVPixelBuffer → JPEG
//
// 镜像链路里唯一的目标是"低延迟 + 别把手机烤熟"，所以：
// 1. 先缩到长边 ≤ maxEdge（默认 1280），1080p 原帧编出来 200KB+，车机浏览器根本吃不下；
// 2. 质量压到 0.5 左右，肉眼在 7 寸车机屏上分不出来；
// 3. 编码丢到串行队列，跟不上就丢帧，别堆。

final class FrameEncoder: @unchecked Sendable {
    private let context = CIContext(options: [
        .cacheIntermediates: false,
        // 软件渲染在 A 系芯片上反而更稳：Metal context 偶尔会在后台被回收
        .useSoftwareRenderer: true,
    ])
    private let queue = DispatchQueue(label: "mirrorcast.encode", qos: .userInitiated)
    private var busy = false
    private let lock = NSLock()

    var maxEdge: CGFloat = 1280
    var quality: Double = 0.5

    /// 非阻塞：上一帧还在编就直接丢这一帧
    func encodeAsync(_ pixelBuffer: CVPixelBuffer,
                     orientation: CGImagePropertyOrientation = .up,
                     completion: @escaping @Sendable (Data?) -> Void) {
        let shouldRun = lock.guarding {
            if busy { return false }
            busy = true
            return true
        }
        guard shouldRun else { completion(nil); return }

        let maxEdge = self.maxEdge
        let quality = self.quality
        queue.async { [weak self] in
            let jpeg = self?.encode(pixelBuffer, orientation: orientation, maxEdge: maxEdge, quality: quality)
            self?.lock.guarding { self?.busy = false }
            completion(jpeg)
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation = .up,
                maxEdge: CGFloat? = nil,
                quality: Double? = nil) -> Data? {
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ci.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        // 先按方向转正，再缩放，顺序反了会得到裁一半的画面
        ci = ci.oriented(orientation)
        let rotated = ci.extent
        let edge = maxEdge ?? self.maxEdge
        let longest = max(rotated.width, rotated.height)
        if longest > edge {
            let scale = edge / longest
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return jpeg(from: cg, quality: quality ?? self.quality)
    }

    private func jpeg(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // 不做 progressive：车机那些老 WebView 对 progressive JPEG 解码普遍卡半拍
            kCGImageDestinationOptimizeColorForSharing: true,
        ]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

