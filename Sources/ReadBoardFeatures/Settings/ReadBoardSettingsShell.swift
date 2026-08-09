import SwiftUI

#if os(macOS)
import AppKit
#endif

public enum ReadBoardSettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general, remote, reader, llm, deps, boards, sources, fetch, content, export, pipeline, cleanup
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "通用"
        case .remote: "远程访问"
        case .reader: "阅读器"
        case .llm: "LLM模型"
        case .deps: "依赖"
        case .boards: "功能开关"
        case .sources: "多平台订阅"
        case .fetch: "全文提取"
        case .content: "AI内容处理"
        case .export: "导出平台"
        case .pipeline: "导出规则"
        case .cleanup: "缓存清理"
        }
    }

    public var icon: String {
        switch self {
        case .general: "gearshape"
        case .remote: "network"
        case .reader: "doc.text"
        case .llm: "brain.head.profile"
        case .deps: "shippingbox"
        case .boards: "square.grid.2x2"
        case .sources: "antenna.radiowaves.left.and.right"
        case .fetch: "doc.viewfinder"
        case .content: "text.badge.plus"
        case .export: "square.and.arrow.up"
        case .pipeline: "arrow.triangle.branch"
        case .cleanup: "trash"
        }
    }
}

public enum ReadBoardSettingsRoute: Equatable, Sendable {
    case page(ReadBoardSettingsPage)
    case module(String)
}

public enum ReadBoardSettingsDestination: Hashable, Sendable {
    case page(ReadBoardSettingsPage)
    case module(String)
}

public struct ReadBoardSettingsModuleDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let icon: String

    public init(id: String, title: String, icon: String = "bubble.left.and.bubble.right.fill") {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

@MainActor
public final class ReadBoardSettingsNavigationStore: ObservableObject {
    public static let shared = ReadBoardSettingsNavigationStore()
    @Published public private(set) var route: ReadBoardSettingsRoute?

    private init() {}

    public func request(_ route: ReadBoardSettingsRoute) { self.route = route }
}

/// Core 和 Go 共用的设置窗口骨架。宿主只负责为页面目的地提供内容，导航、尺寸、
/// 路由定位和窗口标题栏行为保持一份实现。
public struct ReadBoardSettingsShell: View {
    @State private var selection: ReadBoardSettingsDestination
    private let pages: [ReadBoardSettingsPage]
    private let primaryItem: ReadBoardSettingsModuleDescriptor?
    private let modules: [ReadBoardSettingsModuleDescriptor]
    private let route: ReadBoardSettingsRoute?
    private let content: (ReadBoardSettingsDestination) -> AnyView

    public init(
        pages: [ReadBoardSettingsPage] = ReadBoardSettingsPage.allCases,
        primaryItem: ReadBoardSettingsModuleDescriptor? = nil,
        modules: [ReadBoardSettingsModuleDescriptor] = [],
        route: ReadBoardSettingsRoute? = nil,
        content: @escaping (ReadBoardSettingsDestination) -> AnyView
    ) {
        self.pages = pages
        self.primaryItem = primaryItem
        self.modules = modules
        self.route = route
        self.content = content
        _selection = State(initialValue: primaryItem.map { .module($0.id) }
            ?? .page(pages.first ?? .general))
    }

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                if let primaryItem {
                    Label(primaryItem.title, systemImage: primaryItem.icon)
                        .tag(ReadBoardSettingsDestination.module(primaryItem.id))
                }
                ForEach(pages) { page in
                    Label(page.title, systemImage: page.icon)
                        .tag(ReadBoardSettingsDestination.page(page))
                }
                if !modules.isEmpty {
                    Section("Pro 功能") {
                        ForEach(modules) { module in
                            Label(module.title, systemImage: module.icon)
                                .tag(ReadBoardSettingsDestination.module(module.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()
            content(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
        }
        .frame(minWidth: 720, minHeight: 500)
        #if os(macOS)
        .overlay(ReadBoardSettingsWindowAccessor().frame(width: 0, height: 0))
        #endif
        .onAppear { apply(route) }
        .onChange(of: route) { _, value in apply(value) }
    }

    private func apply(_ route: ReadBoardSettingsRoute?) {
        guard let route else { return }
        switch route {
        case .page(let page): selection = .page(page)
        case .module(let identifier): selection = .module(identifier)
        }
    }
}

#if os(macOS)
private struct ReadBoardSettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.titleVisibility = .hidden
            view.window?.titlebarAppearsTransparent = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
