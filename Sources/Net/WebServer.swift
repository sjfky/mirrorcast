import Foundation
import Network

// MARK: - 帧总线
//
// 采集端（App 内 ReplayKit，或录屏扩展经 App Group 文件）把 JPEG 帧 publish 进来，
// HTTP 侧每个 /mjpeg 连接按自己的节奏消费。
// 慢客户端不拖垮快采集端：只保留最新一帧，落后的连接自动跳帧 ——
// 实时镜像必须丢帧，绝不能排队（排队等于延迟无限增长）。

final class FrameBus: @unchecked Sendable {
    private struct Waiter {
        var token: UInt64
        var after: UInt64
        var continuation: CheckedContinuation<Frame, Never>
    }
    struct Frame: Sendable { var seq: UInt64; var jpeg: Data }

    private let lock = NSLock()
    private var latestSeq: UInt64 = 0
    private var latestJPEG: Data?
    private var waiters: [Waiter] = []
    private var nextToken: UInt64 = 1
    private var _publishedCount: UInt64 = 0

    var publishedCount: UInt64 { lock.guarding { _publishedCount } }

    func publish(_ jpeg: Data) {
        guard !jpeg.isEmpty else { return }
        lock.lock()
        latestSeq += 1
        _publishedCount += 1
        latestJPEG = jpeg
        let frame = Frame(seq: latestSeq, jpeg: jpeg)
        let ready = waiters.filter { frame.seq > $0.after }
        let pending = waiters.filter { frame.seq <= $0.after }
        waiters = pending
        lock.unlock()
        for w in ready { w.continuation.resume(returning: frame) }
    }

    var current: Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let jpeg = latestJPEG, latestSeq > 0 else { return nil }
        return Frame(seq: latestSeq, jpeg: jpeg)
    }

    /// 等一帧比 after 更新的；超时返回 nil，调用方自己继续等下一轮。
    func frame(after seq: UInt64, timeout: TimeInterval = 3) async -> Frame? {
        let existing = lock.guarding { () -> Frame? in
            guard let jpeg = latestJPEG, latestSeq > seq else { return nil }
            return Frame(seq: latestSeq, jpeg: jpeg)
        }
        if let existing { return existing }

        let token = lock.guarding { () -> UInt64 in
            let t = nextToken; nextToken += 1; return t
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Frame, Never>) in
                lock.lock()
                if let jpeg = latestJPEG, latestSeq > seq {
                    let hit = Frame(seq: latestSeq, jpeg: jpeg)
                    lock.unlock()
                    cont.resume(returning: hit)
                    return
                }
                waiters.append(Waiter(token: token, after: seq, continuation: cont))
                lock.unlock()
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.abandon(token)
                }
            }
        } onCancel: { [weak self] in
            self?.abandon(token)
        }
    }

    /// 按唯一 token 摘除等待者。摘不到说明已经正常 resume 过，
    /// 这里绝不能再 resume —— 重复 resume 是直接崩溃。
    private func abandon(_ token: UInt64) {
        lock.lock()
        let doomed = waiters.firstIndex(where: { $0.token == token }).map { waiters.remove(at: $0) }
        lock.unlock()
        _ = doomed
    }
}

// MARK: - HTTP 请求

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [URLQueryItem]
    var headers: [String: String]

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    func queryValue(_ name: String) -> String? {
        query.first(where: { $0.name == name })?.value
    }
}

// MARK: - 极简 HTTP/1.1 服务端
//
// 只支持 GET：镜像接收端不需要写操作，实现面越小越不容易出错。

final class WebServer: @unchecked Sendable {
    enum Route: Sendable {
        case html(Data)
        case image(Data, mime: String)
        case json(String)
        case text(Int, String)
        /// 支持 Range 的文件响应。部分 DMR 拉分会先发
        /// `Range: bytes=0-`，只回 200 会被它当成"不支持 seek"而放弃播放
        case file(Data, mime: String)
    }

    private let stateQueue = DispatchQueue(label: "mirrorcast.http.state")
    private var listener: NWListener?
    private var endpoints: [String: Endpoint] = [:]

    private struct Endpoint {
        var handler: @Sendable (HTTPRequest) -> Route
        /// true 表示这条注册是一个**前缀**（比如 /live），动态子路径由 handler 自己判
        var isPrefix: Bool
    }

    private final class StartBox: @unchecked Sendable {
        var ok = false
        var error: String?
    }

    private let frames: FrameBus
    private var boundPort: UInt16 = 0

    var lastError: String? { stateQueue.sync { _lastError } }
    private var _lastError: String?

    var port: UInt16 { stateQueue.sync { boundPort } }
    var isRunning: Bool { stateQueue.sync { listener != nil } }

    init(frames: FrameBus) {
        self.frames = frames
    }

    /// 端口被占就顺次往下试
    @discardableResult
    func start(ports: [UInt16] = [8090, 8091, 8092, 8099, 8000]) -> UInt16? {
        for candidate in ports where tryStart(port: candidate) {
            return candidate
        }
        return nil
    }

    func stop() {
        stateQueue.sync {
            listener?.cancel()
            listener = nil
            boundPort = 0
        }
    }

    func register(_ path: String,
                  prefix: Bool = false,
                  _ handler: @escaping @Sendable (HTTPRequest) -> Route) {
        stateQueue.sync { endpoints[path] = Endpoint(handler: handler, isPrefix: prefix) }
    }

    func unregister(_ path: String) {
        stateQueue.sync { _ = endpoints.removeValue(forKey: path) }
    }

    // MARK: 监听

    private func tryStart(port requested: UInt16) -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: requested) else { return false }

        let box = StartBox()
        let gate = DispatchSemaphore(value: 0)
        let l: NWListener
        do {
            l = try NWListener(using: params, on: nwPort)
        } catch {
            stateQueue.sync { _lastError = error.localizedDescription }
            return false
        }

        // 注意：stateUpdateHandler 与 newConnectionHandler 都在 stateQueue 上回调，
        // 里面**不能再对这个队列 sync**，否则自锁死锁。
        l.stateUpdateHandler = { [weak self, box] state in
            guard let self else { return }
            switch state {
            case .ready:
                box.ok = true
                self.listener = l
                self.boundPort = l.port?.rawValue ?? requested
                self._lastError = nil
                gate.signal()
            case .failed(let err):
                box.ok = false
                box.error = err.localizedDescription
                self._lastError = err.localizedDescription
                self.listener = nil
                gate.signal()
            case .cancelled:
                if self.listener === l { self.listener = nil }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.start(queue: stateQueue)

        _ = gate.wait(timeout: .now() + 2)
        if !box.ok {
            l.cancel()
            if box.error == nil {
                stateQueue.sync { _lastError = "端口 \(requested) 起不来" }
            }
            return false
        }
        return true
    }

    private func accept(_ conn: NWConnection) {
        let work = DispatchQueue.global(qos: .userInitiated)
        conn.start(queue: work)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.serve(conn)
        }
    }

    // MARK: 单条连接

    private func serve(_ conn: NWConnection) async {
        defer { conn.cancel() }
        guard let request = await readRequest(conn) else { return }

        if request.path == "/mjpeg" {
            await streamMJPEG(conn)
            return
        }

        let route: Route
        if let hit = lookup(request.path) {
            route = hit.handler(request)
        } else {
            route = .text(404, "没有这个路径: \(request.path)")
        }

        var body = Data()
        var status = 200
        var headers: [String: String] = [

            "Cache-Control": "no-store",
            "Connection": "close",
            "Access-Control-Allow-Origin": "*",
        ]
        switch route {
        case .html(let d): body = d; headers["Content-Type"] = "text/html; charset=utf-8"
        case .image(let d, let m): body = d; headers["Content-Type"] = m
        case .json(let s): body = Data(s.utf8); headers["Content-Type"] = "application/json"
        case .text(let code, let s): body = Data(s.utf8); status = code; headers["Content-Type"] = "text/plain; charset=utf-8"
        case .file(let data, let mime):
            headers["Content-Type"] = mime
            headers["Accept-Ranges"] = "bytes"
            if let range = Self.parseRange(request.header("range"), total: data.count) {
                body = data.subdata(in: data.startIndex + range.lowerBound ..< data.startIndex + range.upperBound)
                status = 206
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            } else {
                body = data
            }
        }
        headers["Content-Length"] = String(body.count)
        try? await write(conn, Self.head(status: status, headers: headers) + body)
    }

    private func lookup(_ path: String) -> Endpoint? {
        stateQueue.sync {
            if let direct = endpoints[path] { return direct }
            if path == "/" { return endpoints["/index.html"] }
            // 前缀路由：/live/fr-12.m4s 这种动态名字交给注册了 /live 的处理器，
            // 由它自己做白名单校验 —— 绝不把未校验的路径直接拼成文件路径。
            // 取最长匹配，避免以后加了 /live/status 之类更具体的注册被 /live 抢走。
            let candidates = endpoints.filter { _, key in
                key.hasPrefix("/") && path.hasPrefix(key + "/")
            }.map { (key: $0.key, value: $0.value) }
            let best = candidates
                .filter { $0.value.isPrefix }
                .max { $0.key.count < $1.key.count }
            return best?.value
        }
    }

    private func readRequest(_ conn: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        let terminator = Data([0x0d, 0x0a, 0x0d, 0x0a])
        for _ in 0..<32 {
            if let range = buffer.firstRange(of: terminator) {
                let headData = buffer[buffer.startIndex..<range.lowerBound]
                return Self.parseRequest(String(decoding: headData, as: UTF8.self))
            }
            do {
                let (chunk, _, _) = try await conn.receive(minimumIncompleteLength: 1, maximumLength: 8192)
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count > 128_000 { break }
            } catch {
                return nil
            }
        }
        return Self.parseRequest(String(decoding: buffer, as: UTF8.self))
    }

    static func parseRequest(_ head: String) -> HTTPRequest? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headerMap: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headerMap[String(line[..<i]).lowercased()] =
                String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }

        var path = String(parts[1])
        var query: [URLQueryItem] = []
        if let q = path.firstIndex(of: "?") {
            let raw = String(path[path.index(after: q)...])
            path = String(path[..<q])
            query = URLComponents(string: "/?" + raw)?.queryItems ?? []
        }
        return HTTPRequest(method: String(parts[0]).uppercased(),
                          path: path,
                          query: query,
                          headers: headerMap)
    }

    static func head(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// 只支持单区间 `bytes=a-b` / `bytes=a-`。多区间请求直接忽略（回整份 200）
    static func parseRange(_ header: String?, total: Int) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let spec = String(header.dropFirst(6)).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)
        if startStr.isEmpty {
            // suffix: -500 表示最后 500 字节
            guard let n = Int(endStr), n > 0 else { return nil }
            return max(0, total - min(n, total))..<total
        }
        guard let start = Int(startStr), start < total, start >= 0 else { return nil }
        let end = endStr.isEmpty ? total - 1 : min(Int(endStr) ?? (total - 1), total - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 400: return "Bad Request"
        default: return "Status"
        }
    }

    private func write(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    // MARK: 路径 C 的 multipart/x-mixed-replace 实时帧

    private func streamMJPEG(_ conn: NWConnection) async {
        let boundary = "mirrorcast"
        let preamble = Self.head(status: 200, headers: [
            "Content-Type": "multipart/x-mixed-replace; boundary=\(boundary)",
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma": "no-cache",
            "Connection": "close",
        ])
        // 帧前缀用 \r\n 起头，兼容只按 boundary 行切分的简陋 WebView
        let first = frames.current
        var seq = first?.seq ?? 0
        if let first {
            try? await write(conn, preamble + Self.part(first.jpeg, boundary: boundary))
        } else {
            try? await write(conn, preamble)
        }

        while !Task.isCancelled {
            guard let frame = await self.frames.frame(after: seq, timeout: 4) else { continue }
            seq = frame.seq
            do {
                try await write(conn, Self.part(frame.jpeg, boundary: boundary))
            } catch {
                return        // 接收端断开：connection reset 是正常事件，不是错误
            }
        }
    }

    private static func part(_ jpeg: Data, boundary: String) -> Data {
        var out = Data()
        out.append(Data("\r\n--\(boundary)\r\nContent-Type: image/jpeg\r\n".utf8))
        out.append(Data("Content-Length: \(jpeg.count)\r\n\r\n".utf8))
        out.append(jpeg)
        return out
    }
}
