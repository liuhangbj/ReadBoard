import SwiftUI

struct ReadBoardShortcutHelpView: View {
    private let shortcuts: [(String, String)] = [
        ("J / K", "下一篇 / 上一篇"),
        ("S", "收藏或取消收藏"),
        ("空格", "切换已读状态"),
        ("V", "在浏览器打开原文"),
        ("E", "当前范围全部已读"),
        ("F", "聚焦搜索"),
        ("?", "显示快捷键帮助"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("快捷键")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 12)
            ForEach(shortcuts, id: \.0) { shortcut in
                HStack {
                    Text(shortcut.0)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(minWidth: 72, alignment: .center)
                    Text(shortcut.1).font(.system(size: 12))
                    Spacer()
                }
                .padding(.vertical, 6)
                if shortcut.0 != shortcuts.last?.0 { Divider() }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
