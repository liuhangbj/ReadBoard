import Foundation
import SwiftUI

public enum ReadBoardEdition: String, Sendable {
    case community
    case proBeta
    case pro
}

public struct ReadBoardModuleInfo: Hashable, Sendable {
    public let identifier: String
    public let displayName: String
    public let entitlementIdentifier: String?

    public init(
        identifier: String,
        displayName: String,
        entitlementIdentifier: String? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.entitlementIdentifier = entitlementIdentifier
    }
}

/// Pro 与后续扩展模块只实现增量能力；基础版负责生命周期管理。
@MainActor
public protocol ReadBoardModule: AnyObject, Sendable {
    var info: ReadBoardModuleInfo { get }
    func start()
    func stop()
    /// 模块自己的设置/管理页。公开版只负责承载，不了解私有功能内容。
    func makeSettingsView() -> AnyView?
}

public extension ReadBoardModule {
    func start() {}
    func stop() {}
    func makeSettingsView() -> AnyView? { nil }
}

public struct ReadBoardConfiguration: Sendable {
    public let edition: ReadBoardEdition
    public let applicationSupportDirectoryName: String
    public let modules: [any ReadBoardModule]

    public init(
        edition: ReadBoardEdition,
        applicationSupportDirectoryName: String,
        modules: [any ReadBoardModule] = []
    ) {
        self.edition = edition
        self.applicationSupportDirectoryName = applicationSupportDirectoryName
        self.modules = modules
    }

    public static let community = ReadBoardConfiguration(
        edition: .community,
        applicationSupportDirectoryName: "ReadBoard"
    )
}

private struct ReadBoardConfigurationKey: EnvironmentKey {
    static let defaultValue = ReadBoardConfiguration.community
}

public extension EnvironmentValues {
    var readBoardConfiguration: ReadBoardConfiguration {
        get { self[ReadBoardConfigurationKey.self] }
        set { self[ReadBoardConfigurationKey.self] = newValue }
    }
}

enum ReadBoardRuntime {
    static func configure(applicationSupportDirectoryName: String) {
        let name = applicationSupportDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(
            !name.isEmpty && !name.contains("/") && name != "." && name != "..",
            "Invalid ReadBoard application support directory name"
        )
        setenv("READBOARD_APPLICATION_SUPPORT_NAME", name, 1)
    }
}
