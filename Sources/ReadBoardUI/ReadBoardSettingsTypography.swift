import SwiftUI
#if os(macOS)
import AppKit
#endif

/// ReadBoard 界面只使用四档字号。调用方选择语义角色，不直接写字号。
public enum ReadBoardTextRole: Sendable {
    case pageTitle
    case sectionTitle
    case item
    case itemTitle
    case detail
    case micro
    case input

    public var size: CGFloat {
        switch self {
        case .pageTitle: 17
        case .sectionTitle: 13
        case .item, .itemTitle, .detail, .input: 11
        case .micro: 9
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .pageTitle, .itemTitle: .semibold
        case .sectionTitle: .medium
        case .item, .detail, .micro, .input: .regular
        }
    }
}

public extension View {
    func readBoardTextRole(
        _ role: ReadBoardTextRole,
        design: Font.Design = .default
    ) -> some View {
        modifier(ReadBoardTextRoleModifier(role: role, design: design))
    }
}

private struct ReadBoardTextRoleModifier: ViewModifier {
    @Environment(\.readBoardInterfaceFontRaw) private var fontRaw
    @Environment(\.readBoardInterfaceScale) private var scale
    let role: ReadBoardTextRole
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(ReadBoardInterfaceFont.font(
            rawValue: fontRaw,
            size: role.size * scale,
            weight: role.weight,
            design: design))
    }
}

public struct ReadBoardSettingsPageContainer<Content: View>: View {
    private let title: String
    private let content: Content

    public init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .readBoardTextRole(.pageTitle)
                .foregroundStyle(ReadBoardDesign.C.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ReadBoardDesign.Space.sm)
                .padding(.vertical, ReadBoardDesign.Space.md)
            ReadBoardHairline()
            content
                .readBoardTextRole(.item)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct ReadBoardSettingsSectionTitle: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .readBoardTextRole(.sectionTitle)
            .foregroundStyle(ReadBoardDesign.C.text2)
            .textCase(nil)
    }
}

/// 这些尺寸只用于复合输入行。普通 Picker、Toggle、Slider 优先交给原生 Form 布局。
public enum ReadBoardSettingsControlMetrics {
    public static let labelWidth: CGFloat = 68
    public static let inputLabelWidth: CGFloat = 88
    public static let numericWidth: CGFloat = 90
    public static let compactWidth: CGFloat = 180
    public static let standardWidth: CGFloat = 320
    public static let wideWidth: CGFloat = 520
    public static let controlHeight: CGFloat = 28
    public static let iconButtonSize: CGFloat = 28
    public static let rowSpacing: CGFloat = 12
}

public enum ReadBoardSettingsControlWidth: Sendable {
    case numeric
    case compact
    case standard
    case wide
    case fill
}

/// 文本输入只保留两种宽度语义：数字短框，或占满本行剩余空间。
public enum ReadBoardSettingsInputWidth: Sendable {
    case numeric
    case fill
}

public enum ReadBoardSettingsButtonSize: Sendable {
    case regular
    case inline
    case icon
}

public extension View {
    /// 仅供日期、路径选择器等复合控件使用；基础设置控件应使用对应的语义行组件。
    func readBoardSettingsControlWidth(
        _ width: ReadBoardSettingsControlWidth
    ) -> some View {
        modifier(ReadBoardSettingsControlWidthModifier(width: width))
    }

    func readBoardSettingsInput(
        _ width: ReadBoardSettingsInputWidth = .fill,
        design: Font.Design = .default
    ) -> some View {
        labelsHidden()
            .textFieldStyle(.roundedBorder)
            .readBoardTextRole(.input, design: design)
            .modifier(ReadBoardSettingsInputWidthModifier(width: width))
    }

    func readBoardSettingsPicker(
        _ width: ReadBoardSettingsControlWidth = .compact
    ) -> some View {
        labelsHidden()
            .readBoardTextRole(.input)
            .readBoardSettingsControlWidth(width)
    }

    /// 普通按钮高 28；行内按钮更紧凑；纯图标按钮固定 28 × 28。
    func readBoardSettingsButton(
        _ size: ReadBoardSettingsButtonSize = .regular
    ) -> some View {
        modifier(ReadBoardSettingsButtonSizeModifier(size: size))
    }
}

/// 密码输入统一使用掩码和显隐按钮。服务端已保存的秘密只显示占位掩码，
/// 不通过设置快照回传明文；显隐按钮只作用于本次输入的新值。
public struct ReadBoardSettingsPasswordField: View {
    private let placeholder: String
    private let hasStoredSecret: Bool
    private let loadStoredSecret: (@MainActor () async -> String?)?
    @Binding private var text: String
    @State private var revealsText = false
    @State private var isLoadingSecret = false
    @State private var loadedStoredSecret: String?

    public init(
        _ placeholder: String,
        text: Binding<String>,
        hasStoredSecret: Bool = false,
        loadStoredSecret: (@MainActor () async -> String?)? = nil
    ) {
        self.placeholder = placeholder
        self.hasStoredSecret = hasStoredSecret
        self.loadStoredSecret = loadStoredSecret
        _text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealsText {
                    TextField(revealedPlaceholder, text: $text)
                } else {
                    SecureField(hasStoredSecret ? "" : placeholder, text: $text)
                }
            }
            .readBoardSettingsInput()
            .overlay(alignment: .leading) {
                if hasStoredSecret, text.isEmpty, !revealsText {
                    Text("********")
                        .readBoardTextRole(.input)
                        .foregroundStyle(ReadBoardDesign.C.text2)
                        .padding(.leading, 7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }

            Button {
                revealOrHide()
            } label: {
                if isLoadingSecret {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: revealsText ? "eye.slash" : "eye")
                }
            }
            .buttonStyle(ReadBoardQuietButtonStyle())
            .readBoardSettingsButton(.icon)
            .disabled(isLoadingSecret)
            .help(revealsText ? "隐藏密码" : "显示密码")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var revealedPlaceholder: String {
        hasStoredSecret && text.isEmpty ? "已保存；输入新值可替换" : placeholder
    }

    private func revealOrHide() {
        if revealsText {
            if let loadedStoredSecret, text == loadedStoredSecret {
                text = ""
            }
            loadedStoredSecret = nil
            revealsText = false
            return
        }
        guard text.isEmpty, hasStoredSecret, let loadStoredSecret else {
            revealsText = true
            return
        }
        isLoadingSecret = true
        Task { @MainActor in
            if let secret = await loadStoredSecret() {
                text = secret
                loadedStoredSecret = secret
                revealsText = true
            }
            isLoadingSecret = false
        }
    }
}

private struct ReadBoardSettingsInputWidthModifier: ViewModifier {
    let width: ReadBoardSettingsInputWidth

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        switch width {
        case .numeric:
            content.frame(
                width: ReadBoardSettingsControlMetrics.numericWidth,
                alignment: .leading)
        case .fill:
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        content.frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}

private struct ReadBoardSettingsControlWidthModifier: ViewModifier {
    let width: ReadBoardSettingsControlWidth

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        switch width {
        case .numeric:
            content.frame(width: ReadBoardSettingsControlMetrics.numericWidth, alignment: .leading)
        case .compact:
            content.frame(width: ReadBoardSettingsControlMetrics.compactWidth, alignment: .leading)
        case .standard:
            content.frame(width: ReadBoardSettingsControlMetrics.standardWidth, alignment: .leading)
        case .wide:
            content.frame(
                minWidth: ReadBoardSettingsControlMetrics.standardWidth,
                idealWidth: ReadBoardSettingsControlMetrics.wideWidth,
                maxWidth: ReadBoardSettingsControlMetrics.wideWidth,
                alignment: .leading)
        case .fill:
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        content.frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}

private struct ReadBoardSettingsButtonSizeModifier: ViewModifier {
    let size: ReadBoardSettingsButtonSize

    @ViewBuilder
    func body(content: Content) -> some View {
        switch size {
        case .regular:
            content
                .controlSize(.regular)
                .frame(minHeight: ReadBoardSettingsControlMetrics.controlHeight)
        case .inline:
            content
                .controlSize(.small)
                .frame(minHeight: ReadBoardSettingsControlMetrics.controlHeight)
        case .icon:
            content
                .controlSize(.small)
                .frame(
                    width: ReadBoardSettingsControlMetrics.iconButtonSize,
                    height: ReadBoardSettingsControlMetrics.iconButtonSize)
        }
    }
}

/// 开关行：标题固定在左侧，开关固定靠右，不占用中间留白。
public struct ReadBoardSettingsToggleRow: View {
    private let title: String
    private let detail: String?
    @Binding private var isOn: Bool

    public init(
        _ title: String,
        detail: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    public var body: some View {
        HStack(alignment: .center, spacing: ReadBoardSettingsControlMetrics.rowSpacing) {
            settingsLabel(title, detail: detail)
            Spacer(minLength: ReadBoardDesign.Space.lg)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(ReadBoardDesign.C.accent)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 下拉行：标题固定在左侧；菜单按内容自然宽度并靠右。
public struct ReadBoardSettingsPickerRow<SelectionValue: Hashable, Content: View>: View {
    private let title: String
    @Binding private var selection: SelectionValue
    private let content: Content

    public init(
        _ title: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .center,
               spacing: ReadBoardSettingsControlMetrics.rowSpacing) {
            settingsLabel(title)
            Spacer(minLength: ReadBoardDesign.Space.lg)
            Picker("", selection: $selection) { content }
                .labelsHidden()
                .pickerStyle(.menu)
                .readBoardTextRole(.input)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 自定义或多选菜单仍归入“下拉选单”，沿用相同的左右布局。
public struct ReadBoardSettingsMenuRow<Control: View>: View {
    private let title: String
    private let control: Control

    public init(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center,
               spacing: ReadBoardSettingsControlMetrics.rowSpacing) {
            settingsLabel(title)
            Spacer(minLength: ReadBoardDesign.Space.lg)
            control
                .readBoardTextRole(.input)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 只读值行：项目标题使用 11 Semibold，值使用 11 Regular 并靠右。
public struct ReadBoardSettingsValueRow: View {
    private let title: String
    private let value: String

    public init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        HStack(spacing: ReadBoardSettingsControlMetrics.rowSpacing) {
            Text(title)
                .readBoardTextRole(.itemTitle)
                .foregroundStyle(ReadBoardDesign.C.text)
            Spacer(minLength: ReadBoardDesign.Space.lg)
            Text(value)
                .readBoardTextRole(.item)
                .foregroundStyle(ReadBoardDesign.C.text2)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 输入行：标题左对齐，输入控件从统一起点开始并占满剩余宽度。
/// 普通文本、URL 和路径都占满剩余宽度；仅数字输入使用短框。
public struct ReadBoardSettingsInputRow<Control: View>: View {
    private let title: String
    private let detail: String?
    private let control: Control

    public init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline,
               spacing: ReadBoardSettingsControlMetrics.rowSpacing) {
            settingsLabel(title, detail: detail)
                .frame(
                    width: ReadBoardSettingsControlMetrics.inputLabelWidth,
                    alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 设置页统一滑块行：标题与当前值固定在左侧，滑块占满全部剩余宽度。
public struct ReadBoardSettingsSliderRow: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let displayValue: String

    public init(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        displayValue: String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.displayValue = displayValue
    }

    public var body: some View {
        HStack(spacing: ReadBoardSettingsControlMetrics.rowSpacing) {
            settingsLabel(title)
                .frame(
                    width: ReadBoardSettingsControlMetrics.labelWidth,
                    alignment: .leading)
            Text(displayValue)
                .readBoardTextRole(.item)
                .foregroundStyle(ReadBoardDesign.C.text2)
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)
            #if os(macOS)
            ReadBoardStretchSlider(value: $value, range: range, step: step)
                .frame(minWidth: 120, minHeight: 20, maxHeight: 20)
            .layoutPriority(1)
            #else
            Slider(value: $value, in: range, step: step)
                .tint(ReadBoardDesign.C.accent)
                .frame(maxWidth: .infinity)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(macOS)
/// SwiftUI Slider 在 macOS Form 中会维持固有宽度，无法随剩余空间拉伸。
/// 这里仅桥接系统 NSSlider；数值仍由 SwiftUI Binding 单向持有。
private struct ReadBoardStretchSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.altIncrementValue = step
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if abs(slider.doubleValue - value) > 0.000_001 {
            slider.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var parent: ReadBoardStretchSlider

        init(parent: ReadBoardStretchSlider) {
            self.parent = parent
        }

        @MainActor @objc func valueChanged(_ sender: NSSlider) {
            let lower = parent.range.lowerBound
            let stepped = lower + ((sender.doubleValue - lower) / parent.step).rounded() * parent.step
            let clamped = min(max(stepped, lower), parent.range.upperBound)
            sender.doubleValue = clamped
            parent.value = clamped
        }
    }
}
#endif

/// 增减行：标题左对齐；当前值与系统增减控件组成右侧紧凑操作组。
public struct ReadBoardSettingsStepperRow: View {
    private let title: String
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let step: Int
    private let displayValue: String

    public init(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        displayValue: String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.displayValue = displayValue
    }

    public var body: some View {
        HStack(spacing: ReadBoardSettingsControlMetrics.rowSpacing) {
            settingsLabel(title)
            Spacer(minLength: ReadBoardDesign.Space.lg)
            Text(displayValue)
                .readBoardTextRole(.item)
                .foregroundStyle(ReadBoardDesign.C.text2)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@ViewBuilder
@MainActor
private func settingsLabel(_ title: String, detail: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
            .readBoardTextRole(.item)
            .foregroundStyle(ReadBoardDesign.C.text2)
        if let detail {
            Text(detail)
                .readBoardTextRole(.detail)
                .foregroundStyle(ReadBoardDesign.C.text3)
        }
    }
}

/// 页级“保存 / 应用 / 完成”操作统一靠右；取消和次要操作可放在同一行左侧。
public struct ReadBoardSettingsActionRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
