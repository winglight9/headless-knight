import Foundation
import Testing
@testable import HKMKit

/// 英文表的守门测试。
///
/// 这一层最容易烂的方式不是翻错，而是「加了新的中文文案，忘了补英文」——界面上
/// 那一句会静默地停在中文，没人会发现。所以这里把三件事钉住：
/// 每条 `L("…")` 都得有英文、占位符个数要对得上、值不能为空。
@Suite("英文文案表")
struct LocalizationTests {
    /// 仓库根目录。`#filePath` 是编译期写死的绝对路径，
    /// 从 Tests/HeadlessKnightMasterTests/ 往上两级就是了。
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func englishTable() throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Loc.parse(text)
    }

    /// 源码里所有 `L("字面量")` 的 key。
    static func keysInSources() throws -> Set<String> {
        let sources = repoRoot.appendingPathComponent("Sources")
        var keys: Set<String> = []
        let pattern = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_])L\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(Loc.unescape(String(text[captured])))
            }
        }
        return keys
    }

    @Test("每条界面文案都有英文")
    func everyKeyIsTranslated() throws {
        let table = try Self.englishTable()
        let keys = try Self.keysInSources()
        #expect(keys.count > 100, "只扫到 \(keys.count) 条，正则可能没匹配上")
        let missing = keys.subtracting(table.keys).sorted()
        #expect(missing.isEmpty, "缺英文：\(missing.joined(separator: " / "))")
    }

    @Test("占位符对得上")
    func placeholdersMatch() throws {
        let table = try Self.englishTable()
        var broken: [String] = []
        for (key, value) in table {
            let chinese = Loc.placeholders(in: key)
            let english = Loc.placeholders(in: value)
            if chinese != english {
                broken.append("\(key) → \(value)")
            }
        }
        #expect(broken.isEmpty, "占位符不一致：\(broken.joined(separator: " / "))")
    }

    @Test("没有空值")
    func noEmptyValues() throws {
        let table = try Self.englishTable()
        let empty = table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(empty.isEmpty, "空值：\(empty.keys.joined(separator: " / "))")
    }

    @Test("表里每条都能被解析出来")
    func tableParses() throws {
        let table = try Self.englishTable()
        #expect(table.count >= 200, "只解析出 \(table.count) 条，可能有括号或引号写坏了")
    }

    @Test("替换占位符")
    func interpolation() {
        #expect(Loc.interpolate("{0} 小时 {1} 分", [5, 22]) == "5 小时 22 分")
        #expect(Loc.interpolate("{0} apps are blocking sleep", [3]) == "3 apps are blocking sleep")
        #expect(Loc.interpolate("没有占位符", []) == "没有占位符")
    }

    @Test("表里没有的文案原样返回")
    func untranslatedPassesThrough() {
        // 不能断言「中文环境」，因为这条在英文机器上跑也会执行。
        // 真正要守的是：查不到就返回原文，绝不能返回占位符或空白。
        let key = "表里没有的这一条"
        #expect(!Loc.table.keys.contains(key))
        #expect(L(key) == key)
        #expect(L("{0} 与 {1}", "甲", "乙").contains("甲"))
    }
}
