import Foundation
import Darwin

// MARK: - 总控
//
// 两条互相独立的输出路径（照 OpenXPlay 的分法）：
//   A. DLNA 点播  —— 把一个 URL 交给电视/车机自己去拉流，画质无损
//   B. DLNA 直播  —— 屏幕编码成 H.264+AAC 的 HLS，推给支持 live HLS 的 DMR，带声音
//   C. 网页镜像   —— 内置 HTTP 服务出 multipart MJPEG，车机浏览器打开即看到画面
// 三条互不替代：接收端能力决定走哪条。选路逻辑在 UI 上由用户决定，不在代码里猜。

@MainActor
final class CastController: ObservableObject {
    // 发现
    @Published private(set) var renderers: [Renderer] = []
    @Published private(set) var isDiscovering = false
    @Published var selectedID: String?

    // 播放
    @Published private(set) var transport: TransportState = .unknown
    @Published private(set) var position = PlaybackPosition()
    @Published private(set) var currentItem: DIDLItem?
    @Published var volume: Int = 60
    @Published var isPushing = false

    // 镜像
    @Published private(set) var serverPort: UInt16 = 0
    @Published private(set) var frameCount: UInt64 = 0
    /// DLNA 实时镜像开关（写进 App Group，广播扩展启动时读）
    @Published var liveMirrorEnabled: Bool = AppGroupBridge.liveEnabled
    @Published private(set) var liveSegments: Int = 0

    @Published var lastError: String?

    let frames = FrameBus()
    private let discovery = SSDPDiscovery()
    private let soap = SOAPClient()
    private lazy var server = WebServer(frames: frames)
    private lazy var inAppCapture = InAppCapturer(bus: frames)
    private lazy var extPoller = ExtensionFramePoller(bus: frames)

    private var statusTask: Task<Void, Never>?
    private var discoverReset: Task<Void, Never>?
    private var frameCountTask: Task<Void, Never>?

    var selected: Renderer? {
        renderers.first(where: { $0.id == selectedID })
    }

    /// 车机浏览器要访问的地址
    var receiverURL: String? {
        guard serverPort > 0, let ip = Self.localIPv4String() else { return nil }
        return "http://\(ip):\(serverPort)/"
    }

    var mirrorActive: Bool { serverPort > 0 }

    // MARK: 生命周期

    func bootstrap() {
        // 路由闭包是 @Sendable 的，跑在 HTTP 的派发队列上。
        // 所以这里先把要用的对象取成局部常量再捕获 —— 直接在闭包里读 self.serverPort
        // 这种 @MainActor 属性，Swift 6 语言模式下是隔离错误，Swift 5 模式下是真实的竞争读。
        let server = self.server
        let bus = self.frames
        server.register("/index.html") { _ in RouteBuilder.receiverPage() }
        server.register("/snapshot.jpg") { _ in
            guard let jpeg = bus.current?.jpeg else { return .text(503, "还没有帧") }
            return .image(jpeg, mime: "image/jpeg")
        }
        server.register("/status") { _ in
            let streaming = server.port > 0
            return .json("{\"frames\":\(bus.publishedCount),\"streaming\":\(streaming)}")
        }
        // DLNA 实时镜像：读的是广播扩展发布到 App Group 里的 HLS
        LiveStreamRoutes.register(on: server) { AppGroupBridge.hlsDirectory }
        startMirrorServer()
        startDiscovery()
        startFrameCounter()
    }

    func teardown() {
        stopDiscovery()
        statusTask?.cancel()
        frameCountTask?.cancel()
        inAppCapture.stop()
        extPoller.stop()
        server.stop()
    }

    // MARK: - 路径 A：DLNA

    func startDiscovery() {
        isDiscovering = true
        // 探测包一轮 3 发 + 设备最多 MX:2 才回，4 秒后把转圈停掉。
        // 后台的 60 秒周期重探是静默的，不再转圈。
        discoverReset?.cancel()
        discoverReset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.isDiscovering = false }
        }
        discovery.start(refreshInterval: 60) { [weak self] response in
            guard let location = response.location else { return }
            Task { @MainActor [weak self] in
                await self?.absorb(location: location)
            }
        }
    }

    func stopDiscovery() {
        discovery.stop()
        discoverReset?.cancel()
        isDiscovering = false
    }

    func rediscover() {
        for r in renderers { DeviceDescriptionLoader.forget(r.location) }
        renderers.removeAll()
        startDiscovery()
        discovery.reprobe()
    }

    private func absorb(location: URL) async {
        guard let renderer = await DeviceDescriptionLoader.load(location: location) else { return }
        if let idx = renderers.firstIndex(where: { $0.id == renderer.id }) {
            renderers[idx].lastSeen = Date()
            renderers[idx].name = renderer.name
            renderers[idx].avTransport = renderer.avTransport
        } else {
            renderers.append(renderer)
            NSSLog("[发现] \(renderer.name) → \(renderer.avTransport?.controlURL.absoluteString ?? "-")")
        }
    }

    func select(_ renderer: Renderer) {
        selectedID = renderer.id
        currentItem = nil
        transport = .unknown
        position = PlaybackPosition()
        startStatusPolling()
    }

    func push(_ item: DIDLItem) {
        guard let renderer = selected, let svc = renderer.avTransport else {
            lastError = "先选一台支持 DLNA 的设备"
            return
        }
        isPushing = true
        lastError = nil
        let soap = self.soap
        Task { @MainActor [weak self] in
            defer { self?.isPushing = false }
            do {
                let proxy = AVTransportProxy(renderer: renderer, soap: soap)
                try await proxy.setURI(item)
                try await proxy.play()
                self?.currentItem = item
                self?.transport = .playing
                self?.startStatusPolling()
            } catch {
                self?.lastError = "\(renderer.name): \(error.localizedDescription)"
            }
        }
    }

    func pushURLString(_ raw: String, kind: DIDLItem.Kind) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            lastError = "只支持 http(s) 直链，且要填完整地址"
            return
        }
        push(DIDLItem(url: url, kind: kind))
    }

    func pause() { command { try await $0.pause() } }
    func resume() { command { try await $0.play() } }
    func stop() {
        command { try await $0.stop() }
        currentItem = nil
        position = PlaybackPosition()
    }
    func seek(_ seconds: TimeInterval) { command { try await $0.seek(seconds) } }

    func applyVolume() {
        guard let renderer = selected else { return }
        let soap = self.soap
        let value = volume
        Task { @MainActor [weak self] in
            do {
                try await RenderingControlProxy(renderer: renderer, soap: soap).setVolume(value)
            } catch {
                self?.lastError = "音量: \(error.localizedDescription)"
            }
        }
    }

    private func command(_ body: @escaping (AVTransportProxy) async throws -> Void) {
        guard let renderer = selected, renderer.avTransport != nil else {
            lastError = "先选一台支持 DLNA 的设备"
            return
        }
        let soap = self.soap
        lastError = nil
        Task { @MainActor [weak self] in
            do { try await body(AVTransportProxy(renderer: renderer, soap: soap)) }
            catch { self?.lastError = error.localizedDescription }
        }
    }

    private func startStatusPolling() {
        statusTask?.cancel()
        guard let renderer = selected, renderer.avTransport != nil else { return }
        let soap = self.soap
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let proxy = AVTransportProxy(renderer: renderer, soap: soap)
                if let state = try? await proxy.transportInfo() {
                    self?.transport = state
                }
                if let pos = try? await proxy.positionInfo(), pos.duration > 0 {
                    self?.position = pos
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    // MARK: - 路径 B：DLNA 实时镜像

    /// 改了开关要**重新开一次广播**才生效：扩展进程是在 broadcastStarted 里读这个标志的
    func applyLiveMirrorFlag() {
        AppGroupBridge.liveEnabled = liveMirrorEnabled
        lastError = liveMirrorEnabled ? "已开启：下次开始系统录屏时编码器才会起来" : "已关闭"
    }

    var livePlaylistURL: String? {
        guard serverPort > 0, let ip = Self.localIPv4String() else { return nil }
        var c = URLComponents()
        c.scheme = "http"; c.host = ip; c.port = Int(serverPort)
        c.path = LiveStreamRoutes.baseURLPath + "/" + LiveStreamRoutes.playlistName
        return c.url?.absoluteString
    }

    /// 把手机的实时画面当直播流推给所选 DMR
    func pushLiveMirror() {
        guard selected != nil else { lastError = "先选一台支持 DLNA 的设备"; return }
        guard liveMirrorEnabled else { AppGroupBridge.liveEnabled = true; liveMirrorEnabled = true }
        guard serverPort > 0, let ip = Self.localIPv4String() else {
            lastError = "内置服务没起来，推不了直播"
            return
        }
        guard let item = LiveStreamRoutes.item(ip: ip, port: serverPort) else {
            lastError = "本机地址拼不出可用 URL（Wi-Fi 没连？）"
            return
        }
        push(item)
        if liveSegments == 0 {
            lastError = "已推送，但扩展还没产出分片：确认录屏广播已开启、且开关是在开广播之前就打开的"
        }
    }

    func refreshLiveStatus() {
        guard let dir = AppGroupBridge.hlsDirectory,
              let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            liveSegments = 0; return
        }
        liveSegments = items.filter { $0.hasPrefix("fr-") && $0.hasSuffix(".m4s") }.count
    }

    // MARK: - 路径 C：网页镜像

    func startMirrorServer() {
        guard serverPort == 0 else { return }
        if let port = server.start() {
            serverPort = port
        } else {
            lastError = "内置服务起不来：\(server.lastError ?? "未知原因")"
        }
        Task { await extPoller.start() }
    }

    func stopMirrorServer() {
        server.stop()
        serverPort = 0
        Task { await extPoller.stop() }
    }

    /// App 内采集兜底：只能拍到本 App 自己的界面（Apple 的硬限制），
    /// 整机镜像必须走 SampleHandler 那条路，这里仅在录屏广播不可用时做演示。
    var canUseInAppCapture: Bool { inAppCapture.recorderAvailable }
    func startInAppCapture() { inAppCapture.start() }
    func stopInAppCapture() { inAppCapture.stop() }

    private func startFrameCounter() {
        frameCountTask?.cancel()
        let bus = frames
        frameCountTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.frameCount = bus.publishedCount
                self?.refreshLiveStatus()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// 本机 Wi-Fi IPv4。取不到基本只有两种原因：没连 Wi-Fi，或者本地网络权限被拒。
    static func localIPv4String() -> String? {
        guard let addr = SSDPDiscovery.wifiAddress() else { return nil }
        var storage = addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &storage, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - 路由内容

private enum RouteBuilder {
    static func receiverPage() -> WebServer.Route {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web"),
           let data = try? Data(contentsOf: url) {
            return .html(data)
        }
        if let data = Bundle.main.url(forResource: "index", withExtension: "html")
            .flatMap({ try? Data(contentsOf: $0) }) {
            return .html(data)
        }
        return .text(404, "找不到内置接收页，检查 Resources/web/index.html 是否进了 bundle")
    }
}
