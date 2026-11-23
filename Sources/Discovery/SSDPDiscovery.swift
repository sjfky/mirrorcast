import Foundation
import Darwin

// MARK: - SSDP (RFC 5759) 设备发现
//
// 关键设计：这里**不调用 IP_ADD_MEMBERSHIP**，因此不需要
// `com.apple.developer.networking.multicast` 这个受限 entitlement。
// 依据是 RFC 5759 §4：SSDP 的 M-SEARCH 响应默认单播回给请求的源 address:port，
// 不发组播 NOTIFY（那是可选的）。所以我们把 socket 绑在随机端口上
// 主动发 M-SEARCH，再读回来的单播响应即可，DLNA 电视都按这条实现。
//
// 代价：拿不到设备自己主动发的 alive NOTIFY，只能靠周期性重新 M-SEARCH
// 来发现中途上线的设备 —— 下面的 refreshTimer 就是干这个的。

struct SSDPResponse: Sendable {
    var cacheControlMaxAge: Int?
    var date: String?
    var ext: String?
    var location: URL?
    var server: String?
    var st: String?
    var usn: String?
}

enum SSDPTarget: String {
    case rootDevice = "upnp:rootdevice"
    case all = "ssdp:all"
    case avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
}

final class SSDPDiscovery: @unchecked Sendable {
    /// 239.255.255.250。用 inet_addr 现算，不要手写 0xEFBBBBAA 之类的字面量 ——
    /// s_addr 是小端机器上的网络序 4 字节，手算极易反成 250.255.255.239。
    private static let mcastAddr: in_addr_t = inet_addr("239.255.255.250")
    private static let mcastPort: in_port_t = 1900

    /// 控制队列：只跑定时器和非阻塞动作
    private let queue = DispatchQueue(label: "mirrorcast.ssdp")
    /// 阻塞收包专用队列。recvfrom 一进就是最长 1 秒的等待，
    /// 绝不能和控制队列共用 —— 否则定时器排在后面永远发不出 M-SEARCH。
    private let recvQueue = DispatchQueue(label: "mirrorcast.ssdp.recv", qos: .userInitiated)
    private let stateLock = NSLock()
    private var fd: Int32 = -1
    private var runningFlag = false
    private var refreshSource: DispatchSourceTimer?

    /// 回调在收包线程上，调用方自己切主线程
    private var onResponse: (@Sendable (SSDPResponse) -> Void)? {
        get { stateLock.guarding { _onResponse } }
        set { stateLock.guarding { _onResponse = newValue } }
    }
    private var _onResponse: (@Sendable (SSDPResponse) -> Void)?

    var isRunning: Bool {
        stateLock.guarding { runningFlag }
    }

    // MARK: 生命周期

    func start(refreshInterval: TimeInterval = 60,
               onComplete: (@Sendable (SSDPResponse) -> Void)? = nil) {
        let alreadyRunning = stateLock.guarding { () -> Bool in
            if runningFlag { return true }
            runningFlag = true
            return false
        }
        onResponse = onComplete
        guard !alreadyRunning else { return }

        recvQueue.async { [weak self] in self?.run() }
        scheduleRefresh(every: refreshInterval)
    }

    /// 手动补发一轮 M-SEARCH（用户点"重新搜索"时用）。
    /// 这里**故意不 dispatch 到 queue**：sendto 对同一个 fd 多线程是安全的，
    /// 而排进队列会卡在别的活儿后面，用户体验上就是"点了没反应"。
    func reprobe() {
        sendProbes()
    }

    func stop() {
        stateLock.lock()
        runningFlag = false
        stateLock.unlock()

        refreshSource?.cancel()
        refreshSource = nil

        let shouldClose = stateLock.guarding { fd }
        if shouldClose >= 0 {
            // 等收包线程自己退出循环（最多 SO_RCVTIMEO 的 1 秒）再关 fd：
            // 在 recvfrom 还挂着的时候 close，会让它 EBADF 后立刻重进循环白烧一轮
            recvQueue.async { [weak self] in
                guard let self else { return }
                self.stateLock.guarding {
                    if self.fd >= 0 { close(self.fd) }
                    self.fd = -1
                }
            }
        }
        onResponse = nil
    }

    // MARK: socket

    private func run() {
        guard openSocket() else {
            NSSLog("[SSDP] socket 建立失败")
            stateLock.guarding { runningFlag = false }
            return
        }
        sendProbes()

        // 有界阻塞读：SO_RCVTIMEO 保证循环每秒醒一次检查 runningFlag，
        // 否则 stop() 之后 recvfrom 可能永远不返回。
        while isRunning {
            switch readOneDatagram() {
            case .response(let r):
                if let loc = r.location { NSSLog("[SSDP] <- \(loc.absoluteString)") }
                onResponse?(r)   // 局部取一次，避免 stop() 把它置 nil 后再解包
            case .nothing:
                continue
            case .fatal:
                NSSLog("[SSDP] recvfrom 出错，停止发现")
                stateLock.guarding { runningFlag = false }
            }
        }
    }

    private enum ReadOutcome { case response(SSDPResponse), nothing, fatal }

    private func openSocket() -> Bool {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return false }
        disableSIGPIPE()

        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_IP, IP_RECVTTL, &yes, socklen_t(MemoryLayout<Int32>.size))

        var ttl: UInt8 = 4
        setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        // 走 Wi-Fi(en0) 出去。 cellular 在场时路由默认不一定指到 en0，
        // 不强制绑定的话常见"能上网但搜不到设备"。
        if var wifi = Self.wifiAddress() {
            withUnsafePointer(to: &wifi) { ptr in
                ptr.withMemoryRebound(to: in_addr.self, capacity: 1) { addrPtr in
                    var copy = addrPtr.pointee
                    setsockopt(s, IPPROTO_IP, IP_MULTICAST_IF, &copy, socklen_t(MemoryLayout<in_addr>.size))
                }
            }
        }

        var bound = sockaddr_in()
        bound.sin_family = sa_family_t(AF_INET)
        bound.sin_addr = in_addr(s_addr: INADDR_ANY)
        bound.sin_port = 0                               // 随机端口，响应单播回这里
        let bindOK = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else {
            close(s); return false
        }

        stateLock.guarding { fd = s }
        return true
    }

    private func sendProbes() {
        if Self.wifiAddress() == nil {
            NSSLog("[SSDP] 没拿到 en0 地址：检查一下 Wi-Fi 是否连着 / 本地网络权限是否给了")
        }
        let targets: [String] = [SSDPTarget.rootDevice.rawValue,
                                 SSDPTarget.avTransport.rawValue,
                                 SSDPTarget.all.rawValue]
        for st in targets {
            sendProbe(st: st)
            usleep(120_000)
        }
    }

    private func sendProbe(st: String) {
        let sock = stateLock.guarding { fd }
        guard sock >= 0 else { return }

        // Host 必须写 239.255.255.250:1900，部分固件会校验这一行
        let request = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: \(st)\r
        USER-AGENT: \(Self.userAgent)\r
        \r

        """
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_addr = in_addr(s_addr: Self.mcastAddr)
        dest.sin_port = Self.mcastPort.bigEndian          // 网络字节序
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { payload in
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, payload.baseAddress, payload.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func readOneDatagram() -> ReadOutcome {
        let sock = stateLock.guarding { fd }
        guard sock >= 0 else { return .fatal }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        var peer = sockaddr_storage()
        var peerLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &peer) { peerPtr -> Int in
            peerPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(sock, &buffer, buffer.count, 0, sa, &peerLen)
            }
        }
        if n < 0 {
            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { return .nothing }
            return .fatal
        }
        guard n > 0 else { return .nothing }
        guard let text = String(bytes: buffer[0..<n], encoding: .utf8) else { return .nothing }
        return .response(Self.parse(text))
    }

    private func scheduleRefresh(every seconds: TimeInterval) {
        guard seconds > 5 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in self?.sendProbes() }
        timer.resume()
        refreshSource = timer
    }

    private func disableSIGPIPE() {
        var noSIGPIPE: Int32 = 1
        // iOS 上不能用全局 SO_NOSIGPIPE 以外的方式，逐 socket 设置更安全
        setsockopt(stateLock.guarding { fd }, SOL_SOCKET, SO_NOSIGPIPE,
                   &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: 报文解析

    static func parse(_ message: String) -> SSDPResponse {
        var r = SSDPResponse()
        let lines = message.components(separatedBy: "\r\n")
        guard let first = lines.first,
              first.hasPrefix("HTTP/1.") || first.hasPrefix("NOTIFY") else { return r }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).uppercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "CACHE-CONTROL":
                if let eq = value.firstIndex(of: "=") {
                    let tail = value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if let n = Int(tail.dropFirst("max-age=".count)) ?? Int(tail) { r.cacheControlMaxAge = n }
                }
            case "DATE": r.date = value
            case "EXT": r.ext = value
            case "LOCATION": r.location = URL(string: value)
            case "SERVER": r.server = value
            case "ST": r.st = value
            case "USN": r.usn = value
            default: break
            }
        }
        return r
    }

    /// UPnP DeviceArchitecture 要求 UA 形如 "产品/版本 UPnP/1.0 实现/版本"
    static var userAgent: String {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        return "MirrorCast/\(v) UPnP/1.0 MirrorCast/1.0"
    }

    /// 取 en0 的 IPv4，即 Wi-Fi 地址
    static func wifiAddress() -> in_addr? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        var result = in_addr(s_addr: in_addr_t(0))
        var found = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if name == "en0",
               let sa = ifa.ifa_addr,
               Int32(sa.pointee.sa_family) == AF_INET {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    result = sin.pointee.sin_addr
                }
                found = true
                break
            }
            cursor = ifa.ifa_next
        }
        return found ? result : nil
    }
}

