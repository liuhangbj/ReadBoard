import ReadBoardContract
import ReadBoardUI
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ReadBoardArticleShareView: View {
    let item: ContentSummary
    let canExport: Bool
    let onExport: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("分享 / 后处理")
                    .font(.system(size: 15, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(ReadBoardDesign.C.text3)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ReadBoardHairline()

            VStack(spacing: 2) {
                actionRow("复制链接", icon: "link") {
                    copy(item.url)
                    message = "链接已复制"
                }
                actionRow("复制标题 + 链接", icon: "doc.on.doc") {
                    copy("\(item.title)\n\(item.url)")
                    message = "标题和链接已复制"
                }
                actionRow("在浏览器打开原文", icon: "safari") {
                    openOriginal()
                    dismiss()
                }
            }
            .padding(8)

            if canExport {
                ReadBoardHairline()
                actionRow("触发导出规则", icon: "square.and.arrow.up.on.square") {
                    Task {
                        await onExport()
                        message = "已触发手动导出规则"
                    }
                }
                .padding(8)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ReadBoardDesign.C.scoreHigh)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            Spacer()
            ReadBoardHairline()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ReadBoardPrimaryButtonStyle())
            }
            .padding(12)
        }
        .frame(width: 400, height: 430)
    }

    private func actionRow(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13))
            .foregroundStyle(ReadBoardDesign.C.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
    }

    private func openOriginal() {
        guard let url = URL(string: item.url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
