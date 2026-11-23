import Foundation

// MARK: - XML escaping

/// UPnP/DLNA 最容易翻车的一环：DIDL-Lite 元数据本身是一段 XML，
/// 它还要作为 <CurrentMetadata> 的**文本**再嵌进 SOAP 信封，等于转义两次。
/// 少做一次，电视通常回 402 Invalid Args 或 708 Bad Metadata。
enum XMLEscape {
    static func text(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count + 16)
        for ch in raw {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Minimal read-only DOM

/// UPnP 的描述文档都很小，没必要引第三方 XML 库。
enum XMLNodeKind: Equatable {
    case element
    case text
}

struct XMLNode: Sendable {
    let kind: XMLNodeKind
    let name: String
    var attributes: [String: String]
    var children: [XMLNode]
    var characters: String

    init(kind: XMLNodeKind = .element,
         name: String = "",
         attributes: [String: String] = [:],
         children: [XMLNode] = [],
         characters: String = "") {
        self.kind = kind
        self.name = name
        self.attributes = attributes
        self.children = children
        self.characters = characters
    }

    /// 元素的文本内容（直接子节点里的第一个文本）
    var text: String {
        children.first(where: { $0.kind == .text })?.characters.trimmed ?? characters.trimmed
    }

    /// 深度优先找第一个 local-name 匹配的子孙元素
    func first(_ tag: String) -> XMLNode? {
        if kind == .element && name == tag { return self }
        for c in children {
            if let hit = c.first(tag) { return hit }
        }
        return nil
    }

    func childrenNamed(_ tag: String) -> [XMLNode] {
        children.filter { $0.kind == .element && $0.name == tag }
    }

    func all(_ tag: String) -> [XMLNode] {
        var result: [XMLNode] = []
        if kind == .element && name == tag { result.append(self) }
        for c in children { result.append(contentsOf: c.all(tag)) }
        return result
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum XMLDoc {
    static func parse(_ data: Data) -> XMLNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        // 关命名空间处理，按 local name 取值：
        // 设备固件对 u:/dc:/upnp: 前缀和 MediaRenderer:1 / :2 的写法千奇百怪。
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private struct Frame {
            var node: XMLNode
            var text: String = ""
        }
        private var stack: [Frame] = []

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            stack.append(Frame(node: XMLNode(name: Self.local(elementName),
                                            attributes: attributeDict)))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser,
                    foundCDATA buffer: [UInt8]) {
            stack[stack.count - 1].text += String(decoding: buffer, as: UTF8.self)
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard !stack.isEmpty else { return }
            var frame = stack.removeLast()
            var node = frame.node
            if !frame.text.trimmed.isEmpty {
                node.children.append(XMLNode(kind: .text, characters: frame.text))
            }
            if stack.isEmpty {
                root = node
            } else {
                stack[stack.count - 1].node.children.append(node)
            }
        }

        private static func local(_ elementName: String) -> String {
            String(elementName.split(separator: ":", omittingEmptySubsequences: false).last ?? Substring(elementName))
        }
    }
}
