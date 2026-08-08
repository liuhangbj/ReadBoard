import ReadBoardContract

/// 应用组合根持有的稳定服务集合。SwiftUI 只接触这些端口；本地实现可以继续
/// 使用现有单例，未来 HTTP 服务和远程 Reader 也不会改变前端调用契约。
public struct ReadBoardServices: Sendable {
    public let library: any LibraryGateway
    public let contentDetail: any ContentDetailGateway
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
    public let remoteAccess: any RemoteAccessGateway
    public let remoteCapabilities: [RemoteServiceCapability]

    public init(
        library: any LibraryGateway,
        contentDetail: any ContentDetailGateway,
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
        remoteAccess: any RemoteAccessGateway,
        remoteCapabilities: [RemoteServiceCapability] = RemoteServiceCapability.allCases
    ) {
        self.library = library
        self.contentDetail = contentDetail
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
        self.remoteAccess = remoteAccess
        self.remoteCapabilities = remoteCapabilities
    }

    public static var live: ReadBoardServices {
        ReadBoardServices(
            library: LocalReaderGateway(),
            contentDetail: LocalContentDetailGateway(),
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
            remoteAccess: LocalRemoteAccessGateway()
        )
    }
}
