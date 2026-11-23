import Foundation

// MARK: - 设备描述文档解析 (UDA 2.1 §1.1.2)，服务于路径 A/B

enum DeviceDescriptionLoader {
    /// NSCache 自己线程安全；同一台设备的 description.xml 在一次会话里不会变，
    /// 缓存它只是避免每 60 秒重探就重下一遍
    private static let cache = NSCache<NSString, NSData>()
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = ["User-Agent": SSDPDiscovery.userAgent]
        return URLSession(configuration: cfg)
    }()

    /// 失败返回 nil：局域网里总有几台设备返回 404 或者干脆不理你，
    /// 不能因为一台坏设备就把整轮发现卡住。
    static func load(location: URL) async -> Renderer? {
        let key = location.absoluteString as NSString
        var data: Data?
        if let hit = cache.object(forKey: key) {
            data = hit as Data
        } else {
            do {
                let (raw, _) = try await session.data(from: location)
                cache.setObject(raw as NSData, forKey: key, cost: max(raw.count, 1))
                data = raw
            } catch {
                NSSLog("[SSDP] 描述文档取不到 \(location.absoluteString): \(error.localizedDescription)")
                return nil
            }
        }
        guard let data, let root = XMLDoc.parse(data) else { return nil }
        return makeRenderer(from: root, location: location, data: data)
    }

    /// 缓存失效时用（设备重启后 controlURL 可能变）
    static func forget(_ location: URL) {
        cache.removeObject(forKey: location.absoluteString as NSString)
    }

    // MARK: 抽取

    private static func makeRenderer(from root: XMLNode, location: URL, data: Data) -> Renderer? {
        let baseURL = resolveBase(from: root, location: location)

        // 只看 root device 下的 deviceList 里的设备 + root device 本身。
        // MediaRenderer 的 AVTransport 就在自己的 <serviceList> 里，
        // 但有些固件把它塞在子设备里，所以整棵树一起扫。
        let deviceNodes = root.all("device")
        var name: String?
        var modelInfo: String?
        var avTransport: ControlService?
        var renderingControl: ControlService?
        var presentationURL: URL?

        for dev in deviceNodes {
            let services = dev.childrenNamed("serviceList").flatMap { $0.childrenNamed("service") }
            var devHasAVT = false
            for svc in services {
                guard let type = svc.first("serviceType")?.text, !type.isEmpty else { continue }
                let id = svc.first("serviceId")?.text ?? "urn:upnp-org:serviceId:%31"
                guard let controlPath = svc.first("controlURL")?.text, !controlPath.isEmpty else { continue }
                guard let controlURL = absolute(controlPath, base: baseURL) else { continue }
                let service = ControlService(serviceType: type,
                                            serviceId: id,
                                            controlURL: controlURL)
                if type.localizedCaseInsensitiveContains("AVTransport"), avTransport == nil {
                    avTransport = service
                    devHasAVT = true
                } else if type.localizedCaseInsensitiveContains("RenderingControl"), renderingControl == nil {
                    renderingControl = service
                }
            }

            let isRenderer = dev.first("deviceType")?.text.contains("MediaRenderer") ?? false
            if (devHasAVT || isRenderer) && name == nil {
                name = dev.first("friendlyName")?.text
                let model = dev.first("modelName")?.text
                let desc = dev.first("modelDescription")?.text
                modelInfo = [model, desc].compactMap { $0 }.first { !$0.isEmpty }
                if let raw = dev.first("presentationURL")?.text, !raw.isEmpty {
                    presentationURL = absolute(raw, base: baseURL)
                }
            }
        }

        guard let avTransport else { return nil }   // 没有 AVTransport 的设备推不动，直接丢

        let udn = root.first("UDN")?.text
        let id = (udn?.isEmpty == false) ? udn! : location.absoluteString

        return Renderer(id: id,
                        usn: id,
                        name: name?.isEmpty == false ? name! : (location.host ?? "未知设备"),
                        modelInfo: modelInfo,
                        location: location,
                        avTransport: avTransport,
                        renderingControl: renderingControl,
                        presentationURL: presentationURL)
    }

    /// <URLBase> 优先；没有就用 LOCATION 的 scheme://host:port。
    /// 漏了这一步，相对 controlURL（"dmr/AVTransport/control"）会 POST 到错误的 host。
    private static func resolveBase(from root: XMLNode, location: URL) -> URL {
        if let base = root.first("URLBase")?.text, let url = URL(string: base), url.scheme != nil {
            return url
        }
        var comps = URLComponents(url: location, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        return comps?.url ?? location
    }

    private static func absolute(_ path: String, base: URL) -> URL? {
        if let url = URL(string: path), url.scheme != nil { return url }
        if path.hasPrefix("/") {
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.path = path
            return comps?.url
        }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    static func rawDebug(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

