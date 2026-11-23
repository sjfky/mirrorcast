import Foundation

// MARK: - 待推送的媒体条目

struct DIDLItem: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Identifiable {
        case audio, video, image
        var id: String { rawValue }
        var upnpClass: String {
            switch self {
            case .audio: return "object.item.audioItem.musicTrack"
            case .video: return "object.item.videoItem"
            case .image: return "object.item.imageItem.photo"
            }
        }
        var fallbackMIME: String {
            switch self {
            case .audio: return "audio/mpeg"
            case .video: return "video/mp4"
            case .image: return "image/jpeg"
            }
        }
    }

    var id = UUID()
    var url: URL
    var title: String
    var artist: String?
    var album: String?
    var genre: String?
    var durationText: String?      // "0:03:45"，电视进度条要用
    var artworkURL: URL?
    var kind: Kind = .video
    var mimeOverride: String?

    init(url: URL, title: String? = nil, kind: Kind = .video) {
        self.url = url
        self.kind = kind
        // 括号不能省：`??` 比三元结合更紧，写成
        //   title ?? a.isEmpty ? a : b
        // 会被解析成 (title ?? Bool) ? …，是类型错误而不是笔误。
        let derived = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        self.title = (title?.isEmpty == false) ? title! : derived
    }
}

// MARK: - 渲染设备（DLNA DMR）

struct ControlService: Equatable, Sendable {
    var serviceType: String
    var serviceId: String
    var controlURL: URL
}

struct Renderer: Identifiable, Equatable, Sendable {
    let id: String                 // UDN，缺失时退化成 LOCATION
    var usn: String
    var name: String
    var modelInfo: String?
    var location: URL
    var avTransport: ControlService?
    var renderingControl: ControlService?
    var presentationURL: URL?
    var firstSeen = Date()
    var lastSeen = Date()

    /// 只有拿到 AVTransport 才真的能推
    var isPlayable: Bool { avTransport != nil }

    var hostLabel: String { location.host ?? "?" }

    static func == (lhs: Renderer, rhs: Renderer) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.location == rhs.location
            && lhs.avTransport?.controlURL == rhs.avTransport?.controlURL
            && lhs.renderingControl?.controlURL == rhs.renderingControl?.controlURL
            && lhs.lastSeen == rhs.lastSeen
    }
}

// MARK: - MIME 推断

enum MediaType {
    /// 按扩展名猜；猜不出来按媒体类型兜底。
    /// 注意别指望这条规则多准 —— protocolInfo 只是协商，
    /// 电视不支持时它会直接回 715/718 或黑屏，那时只能换源。
    static func mime(for item: DIDLItem) -> String {
        if let o = item.mimeOverride, !o.isEmpty { return o }
        switch item.url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/ogg; codecs=opus"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "ts": return "video/mp2t"
        case "webm": return "video/webm"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "m3u8": return "application/vnd.apple.mpegurl"
        default: return item.kind.fallbackMIME
        }
    }
}

// MARK: - 播放状态

/// rawValue 就是设备回给我们的原文，必须逐字符对上：
/// AVTransport 的 State 变量是**全大写**，且暂停叫 PAUSED_PLAYBACK 不是 PAUSED。
/// 写成小写的话 `TransportState(rawValue: "PLAYING")` 恒为 nil，
/// 界面就永远显示 unknown，很难查。
enum TransportState: String, Equatable {
    case stopped = "STOPPED"
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case transitioning = "TRANSITIONING"
    case noMediaPresent = "NO_MEDIA_PRESENT"
    case unknown

    init(rawValueLike value: String?) {
        // enum 的 init 里不能 guard-else-return（self 还没定值）
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        self = (v?.isEmpty == false) ? (TransportState(rawValue: v!) ?? .unknown) : .unknown
    }
}

struct PlaybackPosition: Equatable, Sendable {
    var relTime: TimeInterval = 0
    var absTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var relCount: Int?
}
