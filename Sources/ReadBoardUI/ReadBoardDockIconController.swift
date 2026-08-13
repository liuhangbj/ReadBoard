#if os(macOS)
import AppKit
import Foundation

/// 标准版、Pro 和 Go 共用的 Dock 图标外观控制器。
///
/// App 包内只需提供 AppIconLight.icns 与 AppIconDark.icns。控制器在启动时
/// 采用当前有效外观，并通过 AppKit 官方支持的 effectiveAppearance KVO 在
/// 应用运行期间实时切换。资源缺失时保留现有图标，不会清空 Dock 图标。
@MainActor
public final class ReadBoardDockIconController {
    public static let shared = ReadBoardDockIconController()

    public enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark

        var resourceName: String {
            switch self {
            case .light: "AppIconLight"
            case .dark: "AppIconDark"
            }
        }
    }

    private var appearanceObservation: NSKeyValueObservation?
    private(set) var currentAppearance: Appearance?
    private(set) var appliedIcon: NSImage?
    private var icons: [Appearance: NSImage] = [:]
    private var isStarted = false

    init() {}

    public func start(
        application: NSApplication = .shared,
        bundle: Bundle = .main
    ) {
        guard !isStarted else {
            applyCurrentAppearance(application: application)
            return
        }

        let bundledIcons: [Appearance: NSImage] = Dictionary(
            uniqueKeysWithValues: Appearance.allCases.compactMap { appearance in
            guard let url = bundle.url(
                forResource: appearance.resourceName,
                withExtension: "icns"),
                  let image = NSImage(contentsOf: url),
                  image.isValid else {
                fputs("[dock-icon] 缺少或无法读取 \(appearance.resourceName).icns\n", stderr)
                return nil
            }
                return (appearance, image)
            })

        start(application: application, icons: bundledIcons)
    }

    func start(
        application: NSApplication,
        icons: [Appearance: NSImage]
    ) {
        guard !isStarted, !icons.isEmpty else {
            applyCurrentAppearance(application: application)
            return
        }

        self.icons = icons
        isStarted = true
        applyCurrentAppearance(application: application)
        appearanceObservation = application.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self, weak application] _, _ in
            Task { @MainActor [weak self, weak application] in
                guard let application else { return }
                self?.applyCurrentAppearance(application: application)
            }
        }
    }

    public static func resolveAppearance(_ appearance: NSAppearance) -> Appearance {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private func applyCurrentAppearance(application: NSApplication) {
        let appearance = Self.resolveAppearance(application.effectiveAppearance)
        guard appearance != currentAppearance, let icon = icons[appearance] else { return }
        application.applicationIconImage = icon
        appliedIcon = icon
        currentAppearance = appearance
        fputs("[dock-icon] 已切换为 \(appearance.rawValue)\n", stderr)
    }
}
#endif
