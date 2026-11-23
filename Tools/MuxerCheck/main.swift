import Foundation

// 只在 Linux 上跑的复用器验证程序，**不要**加进任何 iOS target。
// 用法（Linux 或 macOS 均可）:
//   swiftc -O Tools/MuxerCheck/*.swift Sources/Muxer/*.swift Sources/Support/Log.swift -o /tmp/muxcheck
// 然后:  /tmp/muxcheck /tmp/out 300 30 1.0  &&  python3 Tools/validate_mp4.py /tmp/out

// 注意：main.swift 的顶层变量是**全局且惰性初始化**的，
// 用写在声明之后不会报错，只会静默取到零值 —— 所以参数必须在最前面解析。
// 可参数化：frames / gop / segSeconds，方便跑多组场景
let frameCount = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 120) : 300
let gop = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 30) : 30
let segSeconds = CommandLine.arguments.count > 4 ? (Double(CommandLine.arguments[4]) ?? 1.0) : 1.0
print("场景: frames=\(frameCount) gop=\(gop) seg=\(segSeconds)s")

let spsHex = "6742c028ed00a00b72"                 // 由 Tools/gen_sps.py 生成：1280x720 baseline
let ppsHex = "68ce3880"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/fmp4test"

func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next() {
        out.append(UInt8(String([a, b]), radix: 16) ?? 0)
    }
    return out
}

func toHex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

let sps = unhex(spsHex)
let pps = unhex(ppsHex)

// 1) 自校验位流解析器
if let info = H264.parseSPS(Array(sps.dropFirst())) {
    print("SPS → \(info.width)x\(info.height) profile=\(info.profileIdc) level=\(info.levelIdc)")
} else {
    print("SPS 解析失败"); exit(2)
}

let config = AVCConfig(sps: sps, pps: pps, naluLengthSize: 4, name: "check")
let muxer: FragmentedMP4Muxer
do {
    muxer = try FragmentedMP4Muxer(config: config, timescale: 90_000, segmentSeconds: segSeconds, keepSegments: 4)
} catch {
    print("init 失败: \(error)"); exit(3)
}

// 用真正的落盘泵写，顺带把 HLSLivePump 的写入顺序也验一遍
let pump = HLSLivePump(directory: URL(fileURLWithPath: outDir))
pump.reset()
let initBytes = muxer.initSegment()
pump.publishInitIfNeeded(Data(initBytes))
print("init.mp4 = \(initBytes.count) 字节")

// 2) 造 120 帧 @30fps：每 30 帧一个 IDR
let fps: Int64 = 30
let unit: Int64 = 90_000 / fps
func nal(_ type: Int, _ body: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    let payload: [UInt8] = [UInt8(type)] + body
    let n = UInt32(payload.count)
    out.append(UInt8((n >> 24) & 0xFF)); out.append(UInt8((n >> 16) & 0xFF))
    out.append(UInt8((n >> 8) & 0xFF)); out.append(UInt8(n & 0xFF))
    out.append(contentsOf: payload)
    return out
}

var emitted = 0
var totalSampleBytes = 0
var lastSeq = UInt64(0)
var fragmentBlobs: [[UInt8]] = []
for i in 0..<frameCount {
    let isSync = (i % gop) == 0
    var avcc = nal(isSync ? 5 : 1, [UInt8](repeating: UInt8(i & 0x7F), count: isSync ? 4000 : 900))
    // 真实场景一帧会有多个 NAL（SPS/PPS/AUD + slice），这里也带上，验证多 NAL 累加
    if isSync { avcc = nal(9, [0x00]) + avcc }
    let sample = VideoSample(avcc: avcc,
                             dts: Int64(i) * unit,
                             pts: Int64(i) * unit,
                             duration: unit,
                             isSync: isSync)
    do {
        if let frag = try muxer.append(sample) {
            emitted += 1
            lastSeq = frag.sequence
            totalSampleBytes += frag.bytes.count
            pump.publishSegment(index: frag.sequence, bytes: Data(frag.bytes), playlist: frag.playlist)
            fragmentBlobs.append(frag.bytes)
        }
    } catch {
        print("append 失败于帧 \(i): \(error)"); exit(4)
    }
}
if let tail = try? muxer.flush() {
    emitted += 1
    lastSeq = tail.sequence
    pump.publishSegment(index: tail.sequence, bytes: Data(tail.bytes), playlist: tail.playlist)
    fragmentBlobs.append(tail.bytes)
}

print("切出 \(emitted) 个分片，最后序号 \(lastSeq)，\(muxer.stats) / pump: \(pump.stats)")
print("--- 播放列表 ---")
print(muxer.currentPlaylist)
print("--- 首分片前 48 字节 ---")
if let d = try? Data(contentsOf: URL(fileURLWithPath: outDir + "/fr-0.m4s")) {
    print(toHex([UInt8](d.prefix(48))))
}

let splitterOK = SplitterCheck.run(initBytes: initBytes, fragments: fragmentBlobs)
if !splitterOK { exit(5) }

// MARK: - 切片器验证：把 init + 所有分片拼成一个"正在被写的文件"，
// 以每次多喂一点的方式重复 ingest，检查
//   1) 幂等（同一分片不会被发两次）
//   2) 切出来的字节和原分片**完全一致**
//   3) 未写完的尾巴不会被提前发布

final class SplitterCheck {
    static func run(initBytes: [UInt8], fragments: [[UInt8]]) -> Bool {
        var whole = Data(initBytes)
        for f in fragments { whole.append(Data(f)) }
        let splitter = FragmentedMP4Splitter(keepSegments: 8, mediaTimescale: 90_000)
        var got: [Data] = []
        var offset = 0
        while offset < whole.count {
            offset = min(whole.count, offset + 4093)          // 故意用不整除的步长
            let prefix = whole.subdata(in: 0..<offset)
            for slice in splitter.ingest(prefix) { got.append(slice.bytes) }
        }
        // 最后再喂一次完整文件，必须不再产出新的分片
        let extra = splitter.ingest(whole)
        if !extra.isEmpty {
            print("❌ 重复发布：最后又吐了 \(extra.count) 片"); return false
        }
        if got.count != fragments.count {
            print("❌ 分片数不符：切出 \(got.count)，实际 \(fragments.count)"); return false
        }
        for (i, g) in got.enumerated() {
            let expect = Data(fragments[i])
            if g != expect {
                print("❌ 第 \(i) 片字节不一致：\(g.count) vs \(expect.count)")
                for j in 0..<min(g.count, expect.count) where g[g.startIndex+j] != expect[expect.startIndex+j] {
                    print("   首个差异 @\(j): \(g[g.startIndex+j]) != \(expect[expect.startIndex+j])"); break
                }
                return false
            }
        }
        // 同一批字节当成"一个已写完的多分片文件"再走一遍 extract 接口
        let (initAgain, extracted) = FragmentedMP4Splitter.extractInitAndFragments(whole)
        if initAgain != Data(initBytes) {
            print("❌ extract 的 init 与原始 init 不一致 (\(initAgain.count) vs \(initBytes.count))"); return false
        }
        if extracted.count != fragments.count {
            print("❌ extract 分片数 \(extracted.count) != \(fragments.count)"); return false
        }
        for (i, e) in extracted.enumerated() where e != Data(fragments[i]) {
            print("❌ extract 第 \(i) 片不一致"); return false
        }
        // 单分片文件（AVAssetWriter 每段一个文件的场景）
        for f in fragments {
            var one = Data(initBytes); one.append(Data(f))
            let (i2, fr2) = FragmentedMP4Splitter.extractInitAndFragments(one)
            if fr2.count != 1 || fr2[0] != Data(f) || i2 != Data(initBytes) {
                print("❌ 单分片文件抽取失败"); return false
            }
        }
        print("✅ 切片器：\(got.count) 片字节完全一致、幂等，extract/单片接口均正确")
        print("   playlist → \(splitter.currentPlaylist.split(separator: "\n").prefix(6).joined(separator: " | "))")
        return true
    }
}
