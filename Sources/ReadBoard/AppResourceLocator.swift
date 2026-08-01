import Foundation

/// 统一定位随 App 发布的只读资源与本地运行数据。
///
/// 发布包优先从 Contents/Resources 读取；SwiftPM 开发和测试环境回落到
/// 当前源码 Target 内的 Resources。运行数据始终落在 Application Support，
/// 不再依赖源码仓库路径。
enum AppResourceLocator {
    static var applicationSupportDirectoryName: String {
        let configured = ProcessInfo.processInfo.environment["READBOARD_APPLICATION_SUPPORT_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty,
              !configured.contains("/"), configured != ".", configured != ".." else {
            return "ReadBoard"
        }
        return configured
    }

    static let applicationSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support",
                   isDirectory: true)
        return base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }()

    static var modelsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static var resourceRoots: [URL] {
        var roots: [URL] = []
        if let mainResources = Bundle.main.resourceURL {
            roots.append(mainResources)
        }
        roots.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true))

        // SwiftPM 本地构建与测试回落。#filePath 只用于开发期定位源码资源；
        // 正式 App 总会先命中 Contents/Resources。
        roots.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true))

        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func existingURL(_ relativePath: String, isDirectory: Bool = false) -> URL? {
        let fm = FileManager.default
        for root in resourceRoots {
            let url = root.appendingPathComponent(relativePath, isDirectory: isDirectory)
            var directoryFlag: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &directoryFlag) else { continue }
            if !isDirectory || directoryFlag.boolValue { return url }
        }
        return nil
    }
}
