import Foundation

/// 界面文案的英文层。
///
/// 做法只有一条：**中文原文就是 key**。中文环境下 `L()` 原封不动把中文还回去，
/// 等于没有这一层；英文环境下查 `en.lproj/Localizable.strings`，查不到就退回
/// 中文原文——界面上永远不会出现空白或者 `key.not.found` 这种东西。
///
/// 为什么不走 `NSLocalizedString` + 英文 key：这 500 多条文案本来就是中文写就的，
/// 改成英文 key 得同时动所有调用点和 259 条测试里的断言。用中文当 key，中文那份
/// 代码零改动、零回归，英文只是一张附加的表。
///
/// 占位符故意不用 `printf` 的 `%d` / `%@`：那套要处理类型宽度、`%%` 转义和顺序，
/// 翻译时最容易出错。这里用 `{0}` `{1}`，英文可以随便调换位置。
public enum Loc {
    /// 英文表。只在英文环境下读一次；中文环境下恒为空。
    ///
    /// `nonisolated(unsafe)`：这两个值只在进程启动时写一次，之后全是读；
    /// 语言要换得重启 App，所以不存在运行中改写的竞争。测试里的 `override`
    /// 也是单线程调用。
    nonisolated(unsafe) public private(set) static var table: [String: String] = [:]
    nonisolated(unsafe) public private(set) static var isEnglish: Bool = false

    private static let bootstrap: Void = bootstrapOnce()

    /// 查一条文案，可选替换 `{0}` `{1}`……
    public static func t(_ key: String, _ args: [Any]) -> String {
        _ = bootstrap
        let template = isEnglish ? (table[key] ?? key) : key
        guard !args.isEmpty else { return template }
        return interpolate(template, args)
    }

    /// 测试和诊断用：直接指定语言与表，绕过 Bundle。
    public static func override(table: [String: String], isEnglish: Bool) {
        self.table = table
        self.isEnglish = isEnglish
    }

    private static func bootstrapOnce() -> Void {
        guard isEnglishPreferred() else { return }
        isEnglish = true
        // 直接指到 en.lproj，不走本地化解析：表只有这一份，绕开解析就绕开了
        // 「开发区域是中文、系统语言是第三种」时的任何歧义。
        let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: "en.lproj")
            ?? Bundle.main.path(forResource: "Localizable", ofType: "strings")
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        table = parse(text)
    }

    /// 判断该不该说英文：**除了中文，其它一律英文**。
    ///
    /// 不能用 `Bundle.main.preferredLocalizations`：包里只有 en.lproj，开发区域是
    /// zh_CN，日文 / 德文 / 法文系统全都匹配不上，于是回落到开发区域——实测这三种
    /// 系统拿到的都是 `["zh_CN"]`，界面会变成中文。那是「没人要的语言」，不是回退。
    ///
    /// 所以直接看用户首选语言。macOS 13 起可以在系统设置里给单个 App 指定语言，
    /// 那一层写在 App 自己的 defaults 里，优先于全局设置。
    private static func isEnglishPreferred() -> Bool {
        let override = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
        let preferred = override?.first ?? Locale.preferredLanguages.first ?? "en"
        return !preferred.lowercased().hasPrefix("zh")
    }

    // MARK: - 解析

    /// `"中文" = "English";` 逐条解析。
    ///
    /// 没有用 `NSDictionary(contentsOfFile:)`：它对 `.strings` 的编码要求很挑剔，
    /// 而这个文件是我们自己生成的，格式固定，自己解析反而更可预期。
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var buffer = text
        // 先去掉注释，避免注释里的引号被当成一条记录。
        buffer = stripComments(buffer)
        var index = buffer.startIndex
        while index < buffer.endIndex {
            guard let quoteStart = buffer[index...].firstIndex(of: "\"") else { break }
            guard let (key, afterKey) = readQuoted(buffer, from: quoteStart) else { break }
            var cursor = afterKey
            while cursor < buffer.endIndex, buffer[cursor] != "=", buffer[cursor] != "\"" {
                cursor = buffer.index(after: cursor)
            }
            guard cursor < buffer.endIndex, buffer[cursor] == "=",
                  let quoteValue = buffer[cursor...].firstIndex(of: "\"")
            else { break }
            guard let (value, afterValue) = readQuoted(buffer, from: quoteValue) else { break }
            result[key] = value
            index = afterValue
        }
        return result
    }

    private static func readQuoted(_ text: String, from quote: String.Index) -> (String, String.Index)? {
        var cursor = text.index(after: quote)
        var raw = ""
        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch == "\\" {
                let next = text.index(after: cursor)
                guard next < text.endIndex else { return nil }
                raw.append(ch)
                raw.append(text[next])
                cursor = text.index(after: next)
                continue
            }
            if ch == "\"" {
                return (unescape(raw), text.index(after: cursor))
            }
            raw.append(ch)
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func unescape(_ raw: String) -> String {
        var out = ""
        var iterator = raw.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\" else {
                out.append(ch)
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            default: out.append(next)
            }
        }
        return out
    }

    private static func stripComments(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        var inBlock = false
        var inLine = false
        var inString = false

        func peek(_ offset: Int) -> Character? {
            var cursor = index
            var remaining = offset
            while remaining > 0 {
                cursor = text.index(after: cursor)
                guard cursor < text.endIndex else { return nil }
                remaining -= 1
            }
            return cursor < text.endIndex ? text[cursor] : nil
        }

        while index < text.endIndex {
            let ch = text[index]
            let next = peek(1)

            if inBlock {
                if ch == "*", next == "/" {
                    inBlock = false
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if inLine {
                if ch == "\n" {
                    inLine = false
                    out.append(ch)
                }
                index = text.index(after: index)
                continue
            }
            if inString {
                out.append(ch)
                if ch == "\\", let escaped = next {
                    out.append(escaped)
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                if ch == "\"" { inString = false }
                index = text.index(after: index)
                continue
            }

            if ch == "/", next == "*" {
                inBlock = true
                index = text.index(index, offsetBy: 2)
                continue
            }
            if ch == "/", next == "/" {
                inLine = true
                index = text.index(index, offsetBy: 2)
                continue
            }
            if ch == "\"" { inString = true }
            out.append(ch)
            index = text.index(after: index)
        }
        return out
    }

    // MARK: - 占位符

    /// `{0}` 换成第一个参数。
    public static func interpolate(_ template: String, _ args: [Any]) -> String {
        var out = template
        for (index, arg) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(index)}", with: describe(arg))
        }
        return out
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return string }
        return String(describing: value)
    }

    /// 一条文案里用到的占位符下标，测试用来核对中英文是否对得上。
    public static func placeholders(in text: String) -> Set<Int> {
        var found: Set<Int> = []
        var scan = text[...]
        while let open = scan.firstIndex(of: "{") {
            let rest = scan[scan.index(after: open)...]
            guard let close = rest.firstIndex(of: "}") else { break }
            let body = rest[rest.startIndex..<close]
            if let number = Int(body) { found.insert(number) }
            scan = rest[rest.index(after: close)...]
        }
        return found
    }
}

/// 界面上每一句中文都从这里过一遍。
public func L(_ key: String, _ args: Any...) -> String {
    Loc.t(key, args)
}
