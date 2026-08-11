import SwiftUI
import ReadBoardContract
import ReadBoardFeatures

/// Core / Pro 设置窗口只负责注入本地服务与产品模块；页面和导航全部来自共享 Features。
public struct SettingsView: View {
    @Environment(\.readBoardConfiguration) private var configuration
    @StateObject private var navigation = ReadBoardSettingsNavigationStore.shared
    private let services: ReadBoardServices

    public init(services: ReadBoardServices = .live) {
        self.services = services
    }

    public var body: some View {
        ReadBoardSettingsShell(
            modules: configuration.modules.map {
                ReadBoardSettingsModuleDescriptor(
                    id: $0.info.identifier,
                    title: $0.info.displayName)
            },
            route: navigation.route,
            content: content)
        .tint(Color.rbAccent)
    }

    private func content(_ destination: ReadBoardSettingsDestination) -> AnyView {
        switch destination {
        case .page(let page):
            return switch page {
            case .general: AnyView(ReadBoardGeneralSettingsPane(
                sourceManagement: services.sourceManagement,
                configuration: services.configuration))
            case .remote:
                services.remoteAccess.map { AnyView(RemoteAccessPane(remoteAccess: $0)) }
                    ?? AnyView(ContentUnavailableView(
                        "仅能在服务端设置远程访问", systemImage: "server.rack"))
            case .reader: AnyView(ReadBoardReaderSettingsPane())
            case .llm: AnyView(ReadBoardLLMSettingsPane(
                configuration: services.configuration))
            case .deps: AnyView(ReadBoardDependencySettingsPane(
                configuration: services.configuration,
                dependencyManagement: services.dependencyManagement,
                allowsServerPathEditing: services.remoteAccess != nil))
            case .boards: AnyView(ReadBoardFeatureBoardSettingsPane(
                configuration: services.configuration))
            case .sources: AnyView(ReadBoardPlatformSettingsPane(
                sourceCatalog: services.sourceCatalog,
                authentication: services.authentication,
                configuration: services.configuration,
                permissions: services.permissions))
            case .fetch: AnyView(ReadBoardFulltextSettingsPane(
                configuration: services.configuration))
            case .content: AnyView(ReadBoardAIContentSettingsPane(
                configuration: services.configuration))
            case .export: AnyView(ReadBoardExportPlatformSettingsPane(
                configuration: services.configuration,
                allowsServerPathEditing: services.remoteAccess != nil))
            case .pipeline: AnyView(ReadBoardExportRulesSettingsPane(
                export: services.export,
                sourceCatalog: services.sourceCatalog,
                configuration: services.configuration))
            case .cleanup: AnyView(ReadBoardMaintenanceSettingsPane(
                maintenance: services.maintenance))
            }
        case .module(let identifier):
            if let module = configuration.modules.first(where: {
                $0.info.identifier == identifier
            }), let view = module.makeSettingsView() {
                return view
            }
            return AnyView(ContentUnavailableView(
                "模块不可用", systemImage: "exclamationmark.triangle"))
        }
    }
}
