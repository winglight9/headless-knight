import Foundation

/// 把任意字符串变成 shell 里安全的**一个**词。
///
/// 双引号挡不住 `$(...)` 和反引号：`cp "\(path)"` 在路径叫
/// `/tmp/$(rm -rf ~)` 时照样会执行命令。凡是拼进 `/bin/sh` 正文的东西，
/// 一律先过这里。
///
/// 实现用单引号包裹：单引号里除了单引号自己没有任何特殊字符，
/// 所以只要把 `'` 换成 `'\''`（关引号、转义一个单引号、再开引号）。
public enum ShellQuote {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
