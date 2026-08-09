import ReadBoardContract

/// 兼容既有功能模块命名；权限真源已经下沉到稳定 Contract。
public typealias ReadBoardFeaturePermissions = ReadBoardPermissionSet

/// ReadBoard 完整页面的组合环境。页面只依赖这些 Contract 端口，不能导入数据库、HTTP 客户端或 App 单例。
public struct ReadBoardFeatureEnvironment: Sendable {
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
    public let permissions: ReadBoardFeaturePermissions

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
        permissions: ReadBoardFeaturePermissions
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
        self.permissions = permissions
    }
}
