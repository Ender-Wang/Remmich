import Foundation

/// A native, text-only subset of a server's HTML notice. No web content is loaded or executed.
nonisolated struct ServerLoginMessage {
    struct Style: Equatable {
        var bold = false
        var italic = false
        var warning = false
        var link: URL?
    }

    struct Segment: Equatable {
        var text: String
        let style: Style
    }

    private(set) var segments: [Segment] = []
    var plainText: String {
        segments.map(\.text).joined()
    }

    init(html: String, baseURL: URL) {
        let source = html as NSString
        let tags = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|</?[A-Za-z](?:[^"'<>]|"[^"]*"|'[^']*')*>"#)
        var stack: [(name: String, style: Style)] = []
        var suppressed: String?
        var position = 0
        func currentStyle() -> Style {
            stack.last?.style ?? .init()
        }
        for match in tags.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            if suppressed == nil {
                append(Self.decode(source.substring(with: NSRange(location: position, length: match.range.location - position)))
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression), style: currentStyle())
            }
            position = NSMaxRange(match.range)
            let tag = source.substring(with: match.range)
            guard !tag.hasPrefix("<!--") else { continue }
            let closing = tag.hasPrefix("</")
            let name = String(tag.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber }).lowercased()
            if let hidden = suppressed {
                if closing, name == hidden {
                    suppressed = nil
                }
                continue
            }
            if ["script", "style", "iframe", "object", "template"].contains(name) {
                if !closing {
                    suppressed = name
                }
                continue
            }
            if name == "br" {
                append("\n", style: currentStyle())
            } else if ["p", "div", "li", "ul", "ol", "blockquote"].contains(name),
                      !segments.isEmpty, segments.last?.text.hasSuffix("\n") == false
            {
                append("\n", style: .init())
            }
            if closing {
                if let index = stack.lastIndex(where: { $0.name == name }) {
                    stack.removeSubrange(index...)
                }
                continue
            }
            if name == "li" {
                append("• ", style: currentStyle())
            }
            guard !["br", "hr", "img", "input", "meta", "link", "wbr"].contains(name), !tag.hasSuffix("/>") else { continue }
            var style = currentStyle()
            if ["b", "strong"].contains(name) {
                style.bold = true
            }
            if ["i", "em"].contains(name) {
                style.italic = true
            }
            let attributes = Self.attributes(tag)
            if let css = attributes["style"], css.range(of: #"(?:^|;)\s*color\s*:\s*(?:red|#f00|#ff0000)\s*(?:;|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                style.warning = true
            }
            if name == "a" {
                style.link = nil
                if let href = attributes["href"], let url = URL(string: Self.decode(href), relativeTo: baseURL)?.absoluteURL,
                   let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme)
                {
                    style.link = url
                }
            }
            stack.append((name, style))
        }
        if suppressed == nil {
            append(Self.decode(source.substring(from: position))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression), style: currentStyle())
        }
        while let last = segments.last {
            let trimmed = last.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            segments.removeLast()
            if !trimmed.isEmpty {
                segments.append(.init(text: trimmed, style: last.style))
                break
            }
        }
    }

    private mutating func append(_ text: String, style: Style) {
        let value = segments.isEmpty || segments.last?.text.hasSuffix("\n") == true
            ? text.replacingOccurrences(of: #"^ +"#, with: "", options: .regularExpression) : text
        guard !value.isEmpty else { return }
        if segments.last?.style == style {
            segments[segments.count - 1].text += value
        } else {
            segments.append(.init(text: value, style: style))
        }
    }

    private static func attributes(_ tag: String) -> [String: String] {
        let pattern = try! NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
        let source = tag as NSString
        return pattern.matches(in: tag, range: NSRange(location: 0, length: source.length)).reduce(into: [:]) { result, match in
            let value = (2 ... 4).first { match.range(at: $0).location != NSNotFound }!
            result[source.substring(with: match.range(at: 1)).lowercased()] = source.substring(with: match.range(at: value))
        }
    }

    private static func decode(_ text: String) -> String {
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©", "reg": "®", "bull": "•"]
        let expression = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#\d+|[A-Za-z]+);"#)
        let source = text as NSString
        var result = text
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let key = source.substring(with: match.range(at: 1))
            let number = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16)
                : key.hasPrefix("#") ? UInt32(key.dropFirst()) : nil
            let value = number.flatMap(UnicodeScalar.init).map(String.init) ?? names[key]
            if let value, let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: value)
            }
        }
        return result
    }
}
