import Foundation

// MARK: - UPnP SOAP 控制 (UDA 2.1 §2.1.10)

enum SOAPError: LocalizedError {
    case notReachable(underlying: any Error)
    case badStatus(code: Int, upnpCode: Int?, upnpDesc: String?)
    case faulty(upnpCode: Int?, upnpDesc: String?)
    case noBody

    var errorDescription: String? {
        switch self {
        case .notReachable(let e):
            return "设备不可达：\(e.localizedDescription)（检查是否同一网段 / 路由器有没有开 AP 隔离）"
        case .badStatus(let code, let upnp, let desc):
            var s = "HTTP \(code)"
            if let upnp { s += " / UPnP \(upnp)" }
            if let desc, !desc.isEmpty { s += " \(desc)" }
            return s
        case .faulty(let upnp, let desc):
            guard let upnp else { return "SOAP 调用失败" }
            return "UPnP 错误 \(upnp)：\(desc ?? UPnPErrorCode.text(upnp))"
        case .noBody:
            return "设备返回空响应"
        }
    }
}

/// 常见 UPnP AVTransport 错误码，直接抄标准表；
/// 光靠 errorDescription 经常被固件写成空串，没这个表就只能靠猜。
enum UPnPErrorCode {
    static func text(_ code: Int) -> String {
        switch code {
        case 401: return "Invalid Action"
        case 402: return "Invalid Args"
        case 404: return "Invalid Action Name"
        case 500: return "Action Failed（设备内部错误，常见于元数据不合法或不支持该 URL）"
        case 600: return "Argument Value Invalid"
        case 601: return "Argument Value Out of Range"
        case 602: return "Optional Action Not Implemented"
        case 603: return "Out Of Memory"
        case 604: return "Human Intervention Required"
        case 605: return "String Argument Too Long"
        case 606: return "Certification Failed"
        case 607: return "No Such Session"
        case 700:  return "Not In Transport"
        case 701:  return "Transport State Exists"
        case 702:  return "StatusCode Change / Reject To Change"
        case 703:  return "Transparent Data Missing"
        case 704:  return "Available Dislocated"
        case 705:  return "Operation Cancelled"
        case 706:  return "Absolute Time Not In Current Domain"
        case 707:  return "Illegal seek target"
        case 708:  return "Bad Metadata（DIDL 不合法或缺少 res，试试换 protocolInfo）"
        case 709:  return "Illegal program"
        case 710:  return "Not enough data"
        case 711:  return "Playing format not supported"
        case 712:  return "Transition not available"
        case 713:  return "Read error / No read media present"
        case 714:  return "Media not ready"
        case 715:  return "Track not available（电视解不了这个源）"
        case 716:  return "URI no longer valid（直链过期，重新获取）"
        case 718:  return "Illegal URL（URL 为空或该设备拒绝这个地址）"
        default:   return "参见 UDA / AVTransport 服务规范"
        }
    }
}

/// 有序入参对
struct SOAPArg: Sendable {
    var name: String
    var value: String
    init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

struct SOAPClient: Sendable {
    let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = ["User-Agent": SSDPDiscovery.userAgent]
        session = URLSession(configuration: cfg)
    }

    /// 发一个 action，返回 `<u:XxxResponse>` 下的出参字典（按名字取值）。
    /// 入参必须按 SCPD 声明顺序传 —— 这里用数组而不是字典就是为了这个。
    /// 按字母排序发给电视，SetAVTransportURI 会变成 CurrentMetadata/CurrentURI/InstanceID，
    /// 大量固件直接回 402 Invalid Args，而且很难一眼看出原因。
    @discardableResult
    func call(serviceType: String,
              serviceId: String,
              controlURL: URL,
              action: String,
              args: [SOAPArg]) async throws -> [String: String] {
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        // SOAPAction 必须带双引号，且不含 serviceId
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.envelope(serviceType: serviceType,
                                             action: action,
                                             args: args).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SOAPError.notReachable(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else { throw SOAPError.noBody }

        if http.statusCode == 500 {
            let (code, desc) = Self.upnpError(in: data)
            throw SOAPError.faulty(upnpCode: code, upnpDesc: desc)
        }
        guard (200..<300).contains(http.statusCode) else {
            let (code, desc) = Self.upnpError(in: data)
            throw SOAPError.badStatus(code: http.statusCode, upnpCode: code, upnpDesc: desc)
        }
        guard !data.isEmpty else { return [:] }
        return Self.outputArgs(data: data, action: action)
    }

    // MARK: 信封

    static func envelope(serviceType: String, action: String, args: [SOAPArg]) -> String {
        var body = ""
        for arg in args {
            body += "<\(arg.name)>\(XMLEscape.text(arg.value))</\(arg.name)>\n"
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:\(action) xmlns:u="\(serviceType)">
        \(body)</u:\(action)>
        </s:Body>
        </s:Envelope>

        """
    }

    private static func outputArgs(data: Data, action: String) -> [String: String] {
        guard let root = XMLDoc.parse(data),
              let responseNode = root.first("\(action)Response") else { return [:] }
        var out: [String: String] = [:]
        for child in responseNode.children where child.kind == .element {
            out[child.name] = child.text
        }
        return out
    }

    private static func upnpError(in data: Data) -> (Int?, String?) {
        guard let root = XMLDoc.parse(data) else { return (nil, nil) }
        guard root.first("Fault") != nil || root.first("UPnPError") != nil else { return (nil, nil) }
        let code = Int(root.first("errorCode")?.text ?? "")
        let desc = root.first("errorDescription")?.text
        return (code, desc)
    }
}
