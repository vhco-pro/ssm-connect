import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A minimal XML element tree for EC2 and STS responses. Namespaces are dropped, so
/// elements are found by local name.
final class XMLElement {
    let name: String
    var text = ""
    var children: [XMLElement] = []

    init(name: String) { self.name = name }

    func first(_ name: String) -> XMLElement? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLElement] { children.filter { $0.name == name } }

    static func parse(_ data: Data) -> XMLElement? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLElement?
        var stack: [XMLElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let element = XMLElement(name: elementName)
            stack.last?.children.append(element)
            if root == nil { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if let element = stack.popLast() { element.text = element.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}
