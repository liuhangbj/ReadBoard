#if os(macOS)
import AppKit
import SwiftUI

/// macOS 原生双栏分隔器。SwiftUI 继续拥有两侧内容与状态；AppKit 只负责
/// 连续拖拽、宽度约束和按产品 bundle 自动保存分隔位置。
public struct ReadBoardResizableColumns<Leading: View, Trailing: View>: NSViewRepresentable {
    @Binding private var leadingWidth: Double
    private let leadingMinimum: CGFloat
    private let leadingIdeal: CGFloat
    private let leadingMaximum: CGFloat
    private let trailingMinimum: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    public init(
        leadingWidth: Binding<Double>,
        leadingMinimum: CGFloat,
        leadingIdeal: CGFloat,
        leadingMaximum: CGFloat,
        trailingMinimum: CGFloat,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        _leadingWidth = leadingWidth
        self.leadingMinimum = leadingMinimum
        self.leadingIdeal = leadingIdeal
        self.leadingMaximum = leadingMaximum
        self.trailingMinimum = trailingMinimum
        self.leading = leading()
        self.trailing = trailing()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            leadingWidth: $leadingWidth,
            leadingMinimum: leadingMinimum,
            leadingMaximum: leadingMaximum,
            trailingMinimum: trailingMinimum)
    }

    public func makeNSView(context: Context) -> NSSplitView {
        let splitView = InitialPositionSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let leadingHost = NSHostingView(rootView: leading)
        let trailingHost = NSHostingView(rootView: trailing)
        leadingHost.frame.size = NSSize(width: leadingIdeal, height: 600)
        trailingHost.frame.size = NSSize(width: 800, height: 600)
        splitView.addArrangedSubview(leadingHost)
        splitView.addArrangedSubview(trailingHost)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        context.coordinator.leadingHost = leadingHost
        context.coordinator.trailingHost = trailingHost
        splitView.onDividerDragEnded = { [weak coordinator = context.coordinator] width in
            coordinator?.storeLeadingWidth(width)
        }

        splitView.initialPosition = CGFloat(leadingWidth)
        return splitView
    }

    public func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.leadingWidth = $leadingWidth
        context.coordinator.leadingHost?.rootView = leading
        context.coordinator.trailingHost?.rootView = trailing
    }

    public final class Coordinator: NSObject, NSSplitViewDelegate {
        fileprivate var leadingHost: NSHostingView<Leading>?
        fileprivate var trailingHost: NSHostingView<Trailing>?
        fileprivate var leadingWidth: Binding<Double>
        private let leadingMinimum: CGFloat
        private let leadingMaximum: CGFloat
        private let trailingMinimum: CGFloat

        fileprivate init(
            leadingWidth: Binding<Double>,
            leadingMinimum: CGFloat,
            leadingMaximum: CGFloat,
            trailingMinimum: CGFloat
        ) {
            self.leadingWidth = leadingWidth
            self.leadingMinimum = leadingMinimum
            self.leadingMaximum = leadingMaximum
            self.trailingMinimum = trailingMinimum
        }

        fileprivate func storeLeadingWidth(_ width: CGFloat) {
            guard width.isFinite, width > 0 else { return }
            leadingWidth.wrappedValue = Double(width)
        }

        public func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard dividerIndex == 0 else { return proposedPosition }
            let availableMaximum = splitView.bounds.width
                - splitView.dividerThickness
                - trailingMinimum
            let upperBound = max(0, min(leadingMaximum, availableMaximum))
            let lowerBound = min(leadingMinimum, upperBound)
            return min(max(proposedPosition, lowerBound), upperBound)
        }

        public func splitView(
            _ splitView: NSSplitView,
            shouldAdjustSizeOfSubview view: NSView
        ) -> Bool {
            // 调整窗口大小时优先改变阅读栏，中栏保持用户选择的宽度。
            view === trailingHost
        }

        public func splitView(
            _ splitView: NSSplitView,
            effectiveRect proposedEffectiveRect: NSRect,
            forDrawnRect drawnRect: NSRect,
            ofDividerAt dividerIndex: Int
        ) -> NSRect {
            // 保持 1px 视觉分隔线，同时给鼠标一个更容易命中的拖拽区域。
            drawnRect.insetBy(dx: -4, dy: 0)
        }
    }
}

private final class InitialPositionSplitView: NSSplitView {
    var initialPosition: CGFloat?
    var onDividerDragEnded: ((CGFloat) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, initialPosition != nil else { return }
        // viewDidMoveToWindow 发生时 SwiftUI 容器仍可能只有临时宽度。等本轮布局
        // 完成后再恢复，否则较宽的已保存值会被临时可用空间截断并看似“卡住”。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let initialPosition = self.initialPosition else {
                return
            }
            self.initialPosition = nil
            self.layoutSubtreeIfNeeded()
            self.setPosition(initialPosition, ofDividerAt: 0)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard subviews.count > 1 else { return }
        onDividerDragEnded?(subviews[0].frame.width)
    }
}
#endif
