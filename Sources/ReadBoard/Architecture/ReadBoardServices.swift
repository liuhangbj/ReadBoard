import ReadBoardContract
import ReadBoardFeatures

/// 应用组合根持有的稳定服务集合。SwiftUI 只接触这些端口；本地实现可以继续
/// 使用现有单例，未来 HTTP 服务和远程 Reader 也不会改变前端调用契约。
public struct ReadBoardServices: Sendable {
    public let library: any LibraryGateway
    public let contentDetail: any ContentDetailGateway
    public let mediaPlayback: any MediaPlaybackGateway
    public let processing: any ProcessingGateway
    public let sourceManagement: any SourceManagementGateway
    public let sourceCatalog: any SourceCatalogGateway
    public let sourceOnboarding: any SourceOnboardingGateway
    public let runtimeStatus: any RuntimeStatusGateway
    public let export: any ExportGateway
    public let administration: any AdministrationGateway
    public let configuration: any ConfigurationGateway
    public let authentication: any AuthenticationGateway
    public let maintenance: any MaintenanceGateway
    public let dependencyManagement: (any DependencyManagementGateway)?
    /// 仅宿主机能配置监听地址、配对和设备撤销。远程客户端传 nil，避免用假实现
    /// 把不可用的宿主管理能力伪装成普通连接错误。
    public let remoteAccess: (any RemoteAccessGateway)?
    public let remoteCapabilities: [RemoteServiceCapability]
    public let remoteScopes: [RemoteAccessScope]

    public init(
        library: any LibraryGateway,
        contentDetail: any ContentDetailGateway,
        mediaPlayback: any MediaPlaybackGateway,
        processing: any ProcessingGateway,
        sourceManagement: any SourceManagementGateway,
        sourceCatalog: any SourceCatalogGateway,
        sourceOnboarding: any SourceOnboardingGateway,
        runtimeStatus: any RuntimeStatusGateway,
        export: any ExportGateway,
        administration: any AdministrationGateway,
        configuration: any ConfigurationGateway,
        authentication: any AuthenticationGateway,
        maintenance: any MaintenanceGateway,
        dependencyManagement: (any DependencyManagementGateway)? = nil,
        remoteAccess: (any RemoteAccessGateway)?,
        remoteCapabilities: [RemoteServiceCapability] = RemoteServiceCapability.allCases,
        remoteScopes: [RemoteAccessScope] = RemoteAccessScope.fullControl
    ) {
        self.library = library
        self.contentDetail = contentDetail
        self.mediaPlayback = mediaPlayback
        self.processing = processing
        self.sourceManagement = sourceManagement
        self.sourceCatalog = sourceCatalog
        self.sourceOnboarding = sourceOnboarding
        self.runtimeStatus = runtimeStatus
        self.export = export
        self.administration = administration
        self.configuration = configuration
        self.authentication = authentication
        self.maintenance = maintenance
        self.dependencyManagement = dependencyManagement
        self.remoteAccess = remoteAccess
        self.remoteCapabilities = remoteCapabilities
        self.remoteScopes = remoteScopes
    }

    public var permissions: ReadBoardPermissionSet {
        ReadBoardPermissionSet(capabilities: remoteCapabilities, scopes: remoteScopes)
    }

    public static var live: ReadBoardServices {
        ReadBoardServices(
            library: LocalReaderGateway(),
            contentDetail: LocalContentDetailGateway(),
            mediaPlayback: LocalMediaPlaybackGateway(),
            processing: LocalProcessingGateway(),
            sourceManagement: LocalSourceManagementGateway(),
            sourceCatalog: LocalSourceCatalogGateway(),
            sourceOnboarding: LocalSourceOnboardingGateway(),
            runtimeStatus: LocalRuntimeStatusGateway(),
            export: LocalExportGateway(),
            administration: LocalAdministrationGateway(),
            configuration: LocalConfigurationGateway(),
            authentication: LocalAuthenticationGateway(),
            maintenance: LocalMaintenanceGateway(),
            dependencyManagement: LocalDependencyManagementGateway(),
            remoteAccess: LocalRemoteAccessGateway()
        )
    }

    /// Core 与 Go 共同页面的本地装配入口。数据库对象不得越过这条边界。
    public var featureEnvironment: ReadBoardFeatureEnvironment {
        ReadBoardFeatureEnvironment(
            library: library,
            contentDetail: contentDetail,
            mediaPlayback: mediaPlayback,
            processing: processing,
            sourceManagement: sourceManagement,
            sourceCatalog: sourceCatalog,
            sourceOnboarding: sourceOnboarding,
            runtimeStatus: runtimeStatus,
            export: export,
            administration: administration,
            configuration: configuration,
            authentication: authentication,
            maintenance: maintenance,
            dependencyManagement: dependencyManagement,
            permissions: permissions)
    }
}
