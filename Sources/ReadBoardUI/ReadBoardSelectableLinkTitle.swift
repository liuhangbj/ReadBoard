#if os(macOS)
import AppKit
import SwiftUI

/// 可选择、可换行且保留原文链接行为的阅读器标题。
///
/// SwiftUI 的 `Link` 会先消费拖拽事件，导致内部 `Text.textSelection` 失效。
/// 这里由同一个 NSTextView 同时负责文本选择和 TextKit 原生链接。
public struct ReadBoardSelectableLinkTitle: NSViewRepresentable {
    public let text: String
    public let destination: URL
    public let font: NSFont
    public let normalColor: NSColor
    public let hoverColor: NSColor

    public init(
        text: String,
        destination: URL,
        font: NSFont,
        normalColor: NSColor,
        hoverColor: NSColor
    ) {
        self.text = text
        self.destination = destination
        self.font = font
        self.normalColor = normalColor
        self.hoverColor = hoverColor
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(destination: destination)
    }

    public func makeNSView(context: Context) -> ReadBoardSelectableLinkTextView {
        let view = ReadBoardSelectableLinkTextView()
        view.delegate = context.coordinator
        update(view, coordinator: context.coordinator)
        return view
    }

    public func updateNSView(
        _ nsView: ReadBoardSelectableLinkTextView,
        context: Context
    ) {
        update(nsView, coordinator: context.coordinator)
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ReadBoardSelectableLinkTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.requiredHeight(for: width))
    }

    private func update(
        _ view: ReadBoardSelectableLinkTextView,
        coordinator: Coordinator
    ) {
        coordinator.destination = destination
        view.configure(
            text: text,
            destination: destination,
            font: font,
            normalColor: normalColor,
            hoverColor: hoverColor)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var destination: URL

        init(destination: URL) {
            self.destination = destination
        }

        @MainActor
        public func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            let url = (link as? URL)
                ?? (link as? String).flatMap(URL.init(string:))
                ?? destination
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

public final class ReadBoardSelectableLinkTextView: NSTextView {
    private var hoverTrackingArea: NSTrackingArea?
    private var displayFont = NSFont.systemFont(ofSize: 24, weight: .semibold)
    private var normalColor = NSColor.labelColor
    private var hoverColor = NSColor.controlAccentColor
    private var destinationURL: URL?
    private var hovered = false

    public init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
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
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor,
        ]
        setAccessibilityRole(.link)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(
        text: String,
        destination: URL,
        font: NSFont,
        normalColor: NSColor,
        hoverColor: NSColor
    ) {
        displayFont = font
        self.normalColor = normalColor
        self.hoverColor = hoverColor
        destinationURL = destination
        if string != text { string = text }
        applyAppearance()
        invalidateIntrinsicContentSize()
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    public func requiredHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else {
            return ceil(displayFont.ascender - displayFont.descender)
        }
        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return ceil(max(displayFont.ascender - displayFont.descender, used.height))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0 {
            textContainer?.containerSize = NSSize(
                width: newSize.width,
                height: CGFloat.greatestFiniteMagnitude)
        }
    }

    public override func updateTrackingAreas() {
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

    public override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyAppearance()
    }

    public override func mouseExited(with event: NSEvent) {
        hovered = false
        applyAppearance()
    }

    private func applyAppearance() {
        guard let textStorage else { return }
        let range = NSRange(location: 0, length: textStorage.length)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: displayFont,
            .foregroundColor: hovered ? hoverColor : normalColor,
        ]
        if let destinationURL { attributes[.link] = destinationURL }
        textStorage.setAttributes(attributes, range: range)
        linkTextAttributes = [
            .foregroundColor: hovered ? hoverColor : normalColor,
            .underlineStyle: 0,
        ]
    }
}
#endif
