import AppKit
import SwiftUI

/// 阅读器标题的原生文本桥接：同一个 NSTextView 同时负责选择和 TextKit 原生链接。
/// SwiftUI 只传入内容与样式，不复制任何业务状态。
struct SelectableLinkTitle: NSViewRepresentable {
    let text: String
    let destination: String
    let font: NSFont
    let normalColor: NSColor
    let hoverColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(destination: destination)
    }

    func makeNSView(context: Context) -> RBSelectableLinkTextView {
        let view = RBSelectableLinkTextView()
        view.delegate = context.coordinator
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: RBSelectableLinkTextView, context: Context) {
        update(nsView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: RBSelectableLinkTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.requiredHeight(for: width))
    }

    private func update(_ view: RBSelectableLinkTextView, coordinator: Coordinator) {
        coordinator.destination = destination
        view.configure(
            text: text,
            destination: destination,
            font: font,
            normalColor: normalColor,
            hoverColor: hoverColor)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var destination: String

        init(destination: String) {
            self.destination = destination
        }

        @MainActor
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
                ?? URL(string: destination)
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

final class RBSelectableLinkTextView: NSTextView {
    private var hoverTrackingArea: NSTrackingArea?
    private var displayFont = NSFont.systemFont(ofSize: 24, weight: .bold)
    private var normalColor = NSColor.labelColor
    private var hoverColor = NSColor.controlAccentColor
    private var destinationURL: URL?
    private var hovered = false

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // SwiftUI 通过 sizeThatFits 提供宽度；由 requiredHeight 明确驱动 TextKit 容器，
        // 避免尚未进窗口时 bounds=0 把手动宽度覆盖掉。
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        backgroundColor = .clear
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = true
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude)
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        setAccessibilityRole(.link)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        text: String,
        destination: String,
        font: NSFont,
        normalColor: NSColor,
        hoverColor: NSColor
    ) {
        displayFont = font
        self.normalColor = normalColor
        self.hoverColor = hoverColor
        destinationURL = URL(string: destination)
        if string != text { string = text }
        applyAppearance()
        invalidateIntrinsicContentSize()
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return ceil(displayFont.ascender - displayFont.descender) }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return ceil(max(displayFont.ascender - displayFont.descender, used.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0 {
            textContainer?.containerSize = NSSize(
                width: newSize.width,
                height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyAppearance()
    }

    private func applyAppearance() {
        guard let textStorage else { return }
        let range = NSRange(location: 0, length: textStorage.length)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: displayFont,
            .foregroundColor: hovered ? hoverColor : normalColor
        ]
        if let destinationURL { attributes[.link] = destinationURL }
        textStorage.setAttributes(attributes, range: range)
        linkTextAttributes = [
            .foregroundColor: hovered ? hoverColor : normalColor,
            .underlineStyle: 0
        ]
    }
}
