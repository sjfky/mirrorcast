import Foundation
import AVFoundation
import CoreMedia

// MARK: - 每段一个 AVAssetWriter 会话的 HLS 生产者
//
// 为什么不用"一个 writer 一直写、再去拆增长中的文件"：
//   AVAssetWriter 写作过程中 mdat 的长度字段可能是"直到文件尾"的中间态，
//   增量拆包要么读到半截，要么把没写完的一段误判成完整段。
// 改成"每段一个会话"之后：
//   1) 每段都是 finish 过的完整文件，box 尺寸全是终值，拆包是纯确定性操作；
//   2) 新会话的第一个采样必然是 IDR，天然满足"分片必须以关键帧开头"；
//   3) 音频能一起进同一路流（MJPEG 那条做不到）。
// 代价：段间要重建编码器会话（几十 ms），这期间用有界缓冲接住，不丢帧。

final class HLSSegmentWriter: @unchecked Sendable {
    struct Config {
        var width: Int
        var height: Int
        var videoBitrate: Int = 2_400_000
        var fps: Int = 30
        var segmentSeconds: Double = 2.0
        var keepsAudio = true
        /// 中间态 .mp4 的落盘目录（发布完就删）
        var scratchDirectory: URL
        /// 换段期间的缓冲上限，超了才丢最老的
        var maxBufferedSamples = 90
        var keepSegments = 6
    }

    private let queue = DispatchQueue(label: "mirrorcast.hls.writer", qos: .userInitiated)
    private let pump: HLSLivePump
    private var config: Config

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart = CMTime.invalid
    private var segmentStarted = false
    private var cutting = false
    private var segmentFileIndex = 0
    /// 已发布的全部分片时长，作为下一段的 movieTimeOffset，保证 tfdt 连续
    private var accumulated = CMTime.zero
    private var lastPTS = CMTime.zero
    private var buffered: [(sb: CMSampleBuffer, isVideo: Bool)] = []
    private let window: HLSWindow

    var onError: ((String) -> Void)?

    init(config: Config, pump: HLSLivePump) {
        self.config = config
        self.pump = pump
        self.window = HLSWindow(keepSegments: config.keepSegments)
        try? FileManager.default.createDirectory(at: config.scratchDirectory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: 对外入口

    func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        queue.async { [weak self] in self?.handle(sampleBuffer, isVideo: isVideo) }
    }

    /// 横竖屏切换：宽高变了就立刻收段，下一段用新尺寸起会话（init section 也会重写）
    func reconfigure(width: Int, height: Int) {
        queue.async {
            guard width > 0, height > 0, width != self.config.width || height != self.config.height else { return }
            self.config.width = width
            self.config.height = height
            self.initiateCut()
        }
    }

    func shutdown(_ completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(); return }
            guard self.segmentStarted else { completion(); return }
            self.closeCurrentSegment(isFinal: true, then: completion)
        }
    }

    func resetForNewBroadcast() {
        queue.async {
            self.writer = nil; self.videoInput = nil; self.audioInput = nil
            self.segmentStarted = false; self.cutting = false
            self.accumulated = .zero; self.segmentFileIndex = 0
            self.buffered.removeAll()
        }
        pump.reset()
    }

    var stats: String {
        queue.sync {
            "已发=\(window.nextIndex) 缓冲=\(buffered.count) 累计=\(String(format: "%.2f", CMTimeGetSeconds(accumulated)))s 窗口=\(window.prunedUpperBound)..\(window.nextIndex)"
        }
    }

    // MARK: 采样处理（全部在 queue 上）

    private func handle(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeIsValid(pts) else { return }
        lastPTS = pts

        // 会话还没起来（在等第一个视频帧定宽高/起点），或者正在换段 → 先进缓冲
        if !segmentStarted || cutting {
            enqueue(sampleBuffer, isVideo: isVideo)
            if !segmentStarted { tryStartSession() }
            return
        }

        enqueue(sampleBuffer, isVideo: isVideo)
        drainWhileReady()

        if isVideo, CMTimeGetSeconds(CMTimeSubtract(pts, sessionStart)) >= config.segmentSeconds {
            initiateCut()
        }
    }

    private func enqueue(_ sb: CMSampleBuffer, isVideo: Bool) {
        buffered.append((sb, isVideo))
        if buffered.count > config.maxBufferedSamples {
            // 丢最老保最新：实时镜像里旧帧毫无价值，队列长度才是延迟
            buffered.removeFirst(buffered.count - config.maxBufferedSamples)
        }
    }

    /// 按到达顺序往外冲，遇到第一个"输入还没准备好"就停 —— 这样两条轨道各自的时间戳
    /// 单调性都不会被打破（乱序 append 会让 AVAssetWriter 直接置 failed）
    private func drainWhileReady() {
        while let head = buffered.first {
            if head.isVideo {
                guard let input = videoInput else { return }
                guard input.isReadyForMoreMediaData else { return }
                buffered.removeFirst()
                input.append(head.sb)
            } else {
                if audioInput == nil {
                    makeAudioInputIfNeeded(matching: head.sb)
                    guard audioInput != nil else {
                        buffered.removeFirst()     // 建不起音频输入（比如设备无 AAC 支持）：丢音频，别堵视频
                        continue
                    }
                }
                guard let input = audioInput, input.isReadyForMoreMediaData else { return }
                buffered.removeFirst()
                input.append(head.sb)
            }
        }
    }

    private func tryStartSession() {
        guard !segmentStarted, !cutting,
              let firstVideo = buffered.first(where: { $0.isVideo }) else { return }
        let start = CMSampleBufferGetPresentationTimeStamp(firstVideo.sb)
        do {
            let w = try makeWriter()
            let v = makeVideoInput()
            w.add(v)
            guard w.startWriting() else {
                throw makeError("startWriting 失败: \(w.error?.localizedDescription ?? "无详情")")
            }
            // atSourceTime 用第一个视频帧，而不是 .zero：
            // 广播启动时 ReplayKit 的时间戳是 mach 绝对时间，从 0 起算会得到巨大的负数
            w.startSession(atSourceTime: start)
            writer = w
            videoInput = v
            sessionStart = start
            segmentStarted = true
            drainWhileReady()
        } catch {
            onError?("HLS 会话创建失败: \(error.localizedDescription)")
            buffered.removeAll()
            segmentStarted = false
        }
    }

    private func makeWriter() throws -> AVAssetWriter {
        let url = config.scratchDirectory
            .appendingPathComponent("seg-\(segmentFileIndex)-\(UUID().uuidString.prefix(8)).mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        if CMTimeGetSeconds(accumulated) > 0 {
            // 媒体时间 = (pts - 会话起点) + movieTimeOffset，接上前一段的尾巴
            w.movieTimeOffset = accumulated
        }
        return w
    }

    private func makeVideoInput() -> AVAssetWriterInput {
        let props: [String: Any] = [
            // 关掉 B 帧：pts==dts，既不用写 ctts，也避开"解码顺序≠显示顺序"这一整类问题
            AVVideoAllowFrameReorderingKey: false,
            AVVideoAverageBitRateKey: config.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: config.fps,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(Double(config.fps) * config.segmentSeconds)),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: props,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// 音频轨道等到第一帧音频、拿到真实 ASBD 之后再建，
    /// 免得把 44.1k/48k 猜错导致 AVAssetWriter 报 "input format mismatch"
    private func makeAudioInputIfNeeded(matching sampleBuffer: CMSampleBuffer) {
        guard writer != nil, audioInput == nil, config.keepsAudio else { return }
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let ptr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let asbd = ptr.pointee
        let rate = Int(asbd.mSampleRate)
        let channels = Int(asbd.mChannelsPerFrame)
        guard rate >= 8_000, rate <= 96_000, channels >= 1, channels <= 8 else { return }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 96_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer?.add(input)
        audioInput = input
    }

    // MARK: 收段

    private func initiateCut() {
        guard !cutting else { return }
        drainWhileReady()
        guard segmentStarted else { return }
        cutting = true
        closeCurrentSegment(isFinal: false) {}
    }

    private func closeCurrentSegment(isFinal: Bool, then completion: @escaping @Sendable () -> Void) {
        guard let w = writer, segmentStarted else {
            segmentStarted = false
            cutting = false
            completion()
            return
        }
        let duration = CMTimeSubtract(lastPTS, sessionStart)
        segmentFileIndex += 1
        writer = nil
        videoInput = nil
        audioInput = nil
        segmentStarted = false
        // 必须逐个，漏一个 finish 就永远不回调（官方文档明确要求）
        for output in w.outputs { (output as? AVAssetWriterInput)?.markAsFinished() }

        w.finish { [weak self] in
            guard let self else { completion(); return }
            self.queue.async {
                if w.status == .completed {
                    self.publishFile(at: w.outputURL, duration: duration)
                    if CMTimeGetSeconds(duration) > 0 {
                        self.accumulated = CMTimeAdd(self.accumulated, duration)
                    }
                } else {
                    self.onError?("分段写入失败(\(w.status.rawValue)): \(w.error?.localizedDescription ?? "未知")")
                }
                try? FileManager.default.removeItem(at: w.outputURL)
                self.cutting = false
                if !isFinal {
                    self.drainWhileReady()
                    if !self.segmentStarted { self.tryStartSession() }
                }
                completion()
            }
        }
    }

    /// 从写完的会话文件里取 init + 媒体段，落到 App Group 的发布目录
    private func publishFile(at url: URL, duration: CMTime) {
        guard let data = try? Data(contentsOf: url) else {
            onError?("读不到会话文件 \(url.lastPathComponent)")
            return
        }
        let (ini, frags) = FragmentedMP4Splitter.extractInitAndFragments(data)
        if !ini.isEmpty { pump.publishInitIfNeeded(ini) }
        guard !frags.isEmpty else {
            onError?("会话文件里没解出媒体段: \(url.lastPathComponent) \(data.count) 字节")
            return
        }
        // 一段会话正常只出一个媒体段；真出多个就按顺序编号，逻辑同样成立
        var seconds = CMTimeGetSeconds(duration)
        if !(seconds > 0.05) { seconds = Double(frags.count) * max(0.5, config.segmentSeconds) / Double(frags.count) }
        let per = max(0.001, seconds / Double(frags.count))
        for f in frags {
            let index = window.notePublished(duration: per)
            pump.publishSegment(index: index, bytes: f, playlist: window.playlist())
        }
        pump.pruneSegments(keepFromIndexFrom: window.prunedUpperBound)
    }

    private func makeError(_ text: String) -> NSError {
        NSError(domain: "mirrorcast.hls", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
