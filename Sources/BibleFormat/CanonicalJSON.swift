import Foundation

/// JSON with sorted keys, two-space indents, and a trailing newline, as `sources.lock.json` and `manifest.json`
/// are written.
enum CanonicalJSON {
    static func data(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let compact = try! encoder.encode(value)
        return Data((indent(String(decoding: compact, as: UTF8.self)) + "\n").utf8)
    }

    // JSONEncoder's pretty printer writes `"key" : value` and `{\n\n}` for empty objects, and a file's
    // bytes should not hinge on that implementation detail, so compact output is re-indented here.
    private static func indent(_ compact: String) -> String {
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        let chars = Array(compact)
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        for (index, char) in chars.enumerated() {
            if inString {
                out.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"":
                inString = true
                out.append(char)
            case "{", "[":
                out.append(char)
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if next == "}" || next == "]" { continue }
                depth += 1
                newline()
            case "}", "]":
                let previous = index > 0 ? chars[index - 1] : nil
                if previous != "{" && previous != "[" {
                    depth -= 1
                    newline()
                }
                out.append(char)
            case ",":
                out.append(char)
                newline()
            case ":":
                out += ": "
            default:
                out.append(char)
            }
        }
        return out
    }
}
