import Foundation

// MARK: - AVTransport:1 / RenderingControl:2 Action 封装

struct AVTransportProxy: Sendable {
    let renderer: Renderer
    let soap: SOAPClient

    enum ProxyError: LocalizedError {
        case noService(String)
        var errorDescription: String? {
            switch self {
            case .noService(let name): return "该设备没有暴露 \(name) 服务，无法推送"
            }
        }
    }

    private var svc: ControlService? { renderer.avTransport }

    // MARK: 播放控制（顺序就是 SCPD 里的声明顺序，别改）

    func setURI(_ item: DIDLItem) async throws {
        let service = try service()
        _ = try await soap.call(serviceType: service.serviceType,
                                serviceId: service.serviceId,
                                controlURL: service.controlURL,
                                action: "SetAVTransportURI",
                                args: [.init("InstanceID", "0"),
                                       .init("CurrentURI", item.url.absoluteString),
                                       .init("CurrentURIMetaData", Self.metadata(for: item))])
    }

    /// 换源但不立刻播放（电视会先进 NO_MEDIA_PRESENT→STOPPED）
    func load(_ item: DIDLItem) async throws {
        try await setURI(item)
    }

    func play() async throws {
        let service = try service()
        _ = try await soap.call(serviceType: service.serviceType,
                                serviceId: service.serviceId,
                                controlURL: service.controlURL,
                                action: "Play",
                                args: [.init("InstanceID", "0"), .init("Speed", "1")])
    }

    func pause() async throws {
        let service = try service()
        _ = try await soap.call(serviceType: service.serviceType,
                                serviceId: service.serviceId,
                                controlURL: service.controlURL,
                                action: "Pause",
                                args: [.init("InstanceID", "0")])
    }

    func stop() async throws {
        let service = try service()
        _ = try await soap.call(serviceType: service.serviceType,
                                serviceId: service.serviceId,
                                controlURL: service.controlURL,
                                action: "Stop",
                                args: [.init("InstanceID", "0")])
    }

    /// relTime 模式几乎所有设备都支持；absTime 只有少数支持，所以默认用 rel。
    func seek(_ time: TimeInterval) async throws {
        let service = try service()
        _ = try await soap.call(serviceType: service.serviceType,
                                serviceId: service.serviceId,
                                controlURL: service.controlURL,
                                action: "Seek",
                                args: [.init("InstanceID", "0"),
                                       .init("Unit", "REL_TIME"),
                                       .init("Target", Self.clock(time))])
    }

    func setSpeed(_ speed: String) async throws {
        let service = try service()
        _ = try await soap.call(serviceType: service.serviceType,
                                serviceId: service.serviceId,
                                controlURL: service.controlURL,
                                action: "SetTransportPlaySpeed",
                                args: [.init("InstanceID", "0"), .init("Speed", speed)])
    }

    // MARK: 查询

    func transportInfo() async throws -> TransportState {
        let service = try service()
        let out = try await soap.call(serviceType: service.serviceType,
                                      serviceId: service.serviceId,
                                      controlURL: service.controlURL,
                                      action: "GetTransportInfo",
                                      args: [.init("InstanceID", "0")])
        return TransportState(rawValueLike: out["CurrentTransportState"])
    }

    func positionInfo() async throws -> PlaybackPosition {
        let service = try service()
        let out = try await soap.call(serviceType: service.serviceType,
                                      serviceId: service.serviceId,
                                      controlURL: service.controlURL,
                                      action: "GetPositionInfo",
                                      args: [.init("InstanceID", "0")])
        var pos = PlaybackPosition()
        pos.relTime = Self.seconds(out["RelTime"])
        pos.absTime = Self.seconds(out["AbsTime"])
        pos.duration = Self.seconds(out["TrackDuration"])
        pos.relCount = Int(out["RelCount"] ?? "")
        return pos
    }

    /// 用来判断"电视到底有没有真的拿到源"
    func mediaInfo() async throws -> (currentURI: String, nextURI: String, duration: String, nbTracks: Int) {
        let service = try service()
        let out = try await soap.call(serviceType: service.serviceType,
                                      serviceId: service.serviceId,
                                      controlURL: service.controlURL,
                                      action: "GetMediaInfo",
                                      args: [.init("InstanceID", "0")])
        return (out["CurrentURI"] ?? "",
                out["NextURI"] ?? "",
                out["MediaDuration"] ?? "0:00:00",
                Int(out["NrTracks"] ?? "") ?? 0)
    }

    private func service() throws -> ControlService {
        guard let svc else { throw ProxyError.noService("AVTransport") }
        return svc
    }

    // MARK: DIDL-Lite

    /// 很多电视（尤其老款）拿到空 CurrentURIMetaData 会直接拒绝播放或不出标题。
    /// 这里生成最小可用 DIDL：<res> 带 protocolInfo，<upnp:class> 与 kind 对应。
    static func metadata(for item: DIDLItem) -> String {
        let mime = MediaType.mime(for: item)
        let protocolInfo = "http-get:*:\(mime):DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        var inner = ""
        inner += "<dc:title>\(XMLEscape.text(item.title))</dc:title>"
        inner += "<upnp:class>\(XMLEscape.text(item.kind.upnpClass))</upnp:class>"
        if let artist = item.artist, !artist.isEmpty {
            inner += "<dc:creator>\(XMLEscape.text(artist))</dc:creator>"
            inner += "<upnp:artist>\(XMLEscape.text(artist))</upnp:artist>"
        }
        if let album = item.album, !album.isEmpty {
            inner += "<upnp:album>\(XMLEscape.text(album))</upnp:album>"
        }
        if let genre = item.genre, !genre.isEmpty {
            inner += "<upnp:genre>\(XMLEscape.text(genre))</upnp:genre>"
        }
        if let duration = item.durationText, !duration.isEmpty {
            inner += "<upnp:duration>\(XMLEscape.text(duration))</upnp:duration>"
        }
        if let art = item.artworkURL {
            inner += "<upnp:albumArtURI>\(XMLEscape.text(art.absoluteString))</upnp:albumArtURI>"
        }
        inner += "<res protocolInfo=\"\(XMLEscape.text(protocolInfo))\""
        if let duration = item.durationText, !duration.isEmpty {
            inner += " duration=\"\(XMLEscape.text(duration))\""
        }
        inner += ">\(XMLEscape.text(item.url.absoluteString))</res>"

        // 返回的是**未转义的合法 DIDL 原文**。
        // 转义只做一处：SOAPClient.envelope 把它塞进 <CurrentURIMetaData> 时统一 escape。
        // 这里再 escape 一次就会变成 SOAP 里的 &amp;lt;，电视解出来是文本节点而不是标签，
        // 表现为 708 Bad Metadata 或直接黑屏 —— 这是 DLNA 推送最常见的坑。
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\""
            + " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\""
            + " xmlns:dlna=\"urn:schemas-dlna-org:metadata-1-0/\">"
            + inner
            + "</DIDL-Lite>"
    }

    // MARK: 时间格式

    /// AVTransport 用 "H:MM:SS" 或 "HH:MM:SS"，不是 SMTPE-TC，也不是毫秒
    static func clock(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00:00" }
        let total = Int(interval.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func seconds(_ clock: String?) -> TimeInterval {
        guard let clock, !clock.isEmpty, clock != "00:00:00:00" else { return 0 }
        // 兼容 "H:MM:SS" 和 SMTPE "HH:MM:SS:FF"
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3...: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default:   return 0
        }
    }
}

// MARK: - RenderingControl:2（音量）

struct RenderingControlProxy: Sendable {
    let renderer: Renderer
    let soap: SOAPClient

    var service: ControlService? { renderer.renderingControl }

    func setVolume(_ percent: Int) async throws {
        guard let service else { return }   // 没有该服务的设备（音箱常见）静默跳过
        _ = try await soap.call(serviceType: service.serviceType,
                                serviceId: service.serviceId,
                                controlURL: service.controlURL,
                                action: "SetVolume",
                                args: [.init("InstanceID", "0"),
                                       .init("Channel", "Master"),
                                       .init("DesiredVolume", String(max(0, min(100, percent))))])
    }

    func currentVolume() async throws -> Int? {
        guard let service else { return nil }
        let out = try await soap.call(serviceType: service.serviceType,
                                      serviceId: service.serviceId,
                                      controlURL: service.controlURL,
                                      action: "GetVolume",
                                      args: [.init("InstanceID", "0"), .init("Channel", "Master")])
        return Int(out["CurrentVolume"] ?? "")
    }
}

