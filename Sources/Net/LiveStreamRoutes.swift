import Foundation

// MARK: - /live/* 路由（把 App Group 里发布好的 HLS 暴露给 DLNA）
//
// 生产者（广播扩展）和这里唯一的接口就是那三个文件名，
// 两个进程通过 App Group 目录解耦，扩展被系统回收也不会让服务端崩。

enum LiveStreamRoutes {
    static let baseURLPath = "/live"
    static let playlistName = "stream.m3u8"
    static let initName = "init.mp4"

    /// 注册路由。directory 用闭包传，这样服务端不持有目录快照、
    /// App Group 容器换了路径也不用改这里
    static func register(on server: WebServer, directory: @escaping @Sendable () -> URL?) {
        server.register(baseURLPath + "/" + playlistName) { _ in
            // 播放列表虽然也走 .file（支持 Range），但它每次都从磁盘现读，
            // 缓存 1 秒都会让电视一直播旧窗口
            serve(directory(), name: playlistName, mime: "application/vnd.apple.mpegurl")
        }
        server.register(baseURLPath + "/" + initName) { _ in
            serve(directory(), name: initName, mime: "video/mp4")
        }
        server.register(baseURLPath + "/status") { _ in jsonStatus(directory()) }
        // 动态分片名 /live/fr-<n>.m4s 走前缀路由，由 segmentName 做白名单
        server.register(baseURLPath, prefix: true) { request in
            guard let name = segmentName(from: request.path) else {
                return .text(400, "非法的分片名")
            }
            return serve(directory(), name: name, mime: "video/mp4")
        }
    }

    /// 从 /live/fr-12.m4s 里取安全文件名；任何越界写法一律拒绝
    static func segmentName(from path: String) -> String? {
        let prefix = baseURLPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let raw = String(path.dropFirst(prefix.count))
        guard raw.hasPrefix("fr-"), raw.hasSuffix(".m4s") else { return nil }
        let digits = raw.dropFirst(3).dropLast(4)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return "fr-\(digits).m4s"
    }

    private static func serve(_ directory: URL?, name: String, mime: String) -> WebServer.Route {
        guard let directory else { return .text(503, "App Group 不可用") }
        // name 只可能来自上面的三个固定串或 segmentName 的白名单重建结果，
        // 因此不存在 "/live/../xxx" 这种穿越到容器外面去读文件的可能
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            return .text(404, "没有 \(name)：广播还没产出分片")
        }
        return .file(data, mime: mime)
    }

    private static func jsonStatus(_ directory: URL?) -> WebServer.Route {
        guard let directory,
              let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return .json("{\"ready\":false}")
        }
        let segs = items.filter { $0.hasPrefix("fr-") && $0.hasSuffix(".m4s") }
        let hasInit = items.contains("init.mp4")
        var bytes = 0
        for name in items {
            let values = try? directory.appendingPathComponent(name)
                .resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            bytes += values?.fileSize ?? 0
        }
        return .json("{\"ready\":\(hasInit && !segs.isEmpty),\"segments\":\(segs.count),"
                   + "\"init\":\(hasInit),\"bytes\":\(bytes)}")
    }

    /// 推给 DLNA 的那个条目。地址拼不出来就返回 nil，让调用方去提示用户，
    /// 而不是硬塞一个假 URL 过去（也别用 force unwrap 把 App 弄崩）
    static func item(ip: String, port: UInt16) -> DIDLItem? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = ip
        components.port = Int(port)
        components.path = baseURLPath + "/" + playlistName
        guard let url = components.url else { return nil }
        var item = DIDLItem(url: url, title: "iPhone 屏幕镜像", kind: .video)
        // 显式给 MIME：靠扩展名推出来的类型有些 DMR 不认
        item.mimeOverride = "application/vnd.apple.mpegurl"
        return item
    }
}
