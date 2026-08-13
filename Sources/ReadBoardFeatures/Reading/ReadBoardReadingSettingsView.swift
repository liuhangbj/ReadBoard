import ReadBoardUI
import SwiftUI

public enum ReadBoardReadingSettingsPresentation: Sendable {
    case popover
    case settingsPane
}

public struct ReadBoardReadingSettingsView: View {
    @AppStorage("reading.theme") private var themeRaw = ReadBoardReadingTheme.claude.rawValue
    @AppStorage("reading.themeMode") private var themeModeRaw = ReadBoardReadingColorMode.system.rawValue
    @AppStorage("reading.font") private var fontRaw = "system"
    @AppStorage("reading.interfaceFont") private var interfaceFontRaw = "system"
    @AppStorage("reading.fontSize") private var fontSize: Double = 16
    @AppStorage("reading.titleFontSize") private var titleFontSize: Double = 24
    @AppStorage("reading.metaFontSize") private var metaFontSize: Double = 12
    @AppStorage("reading.summaryFontSize") private var summaryFontSize: Double = 14
    @AppStorage("reading.lineSpacing") private var lineSpacing: Double = 6
    @AppStorage("reading.contentWidth") private var contentWidth: Double = 720
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1
    @AppStorage("list.density") private var density = "comfortable"
    @AppStorage("list.showSource") private var showSource = true
    @AppStorage("list.showDate") private var showDate = true
    @AppStorage("list.unreadBold") private var unreadBold = true
    @AppStorage("list.dateFormat") private var dateFormat = "absolute"
    private let presentation: ReadBoardReadingSettingsPresentation

    public init(presentation: ReadBoardReadingSettingsPresentation = .popover) {
        self.presentation = presentation
    }

    public var body: some View {
        VStack(spacing: 0) {
            if presentation == .popover {
                HStack {
                    Text("阅读器设置")
                        .readBoardTextRole(.itemTitle)
                    Spacer()
                    Button("恢复默认", action: restoreDefaults)
                        .buttonStyle(ReadBoardSecondaryButtonStyle())
                        .readBoardSettingsButton(.inline)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }

            Form {
                Section {
                    settingsPicker("主题", selection: $themeRaw) {
                            ForEach(ReadBoardReadingTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme.rawValue)
                            }
                        }
                    settingsPicker("亮暗", selection: $themeModeRaw) {
                        ForEach(ReadBoardReadingColorMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    settingsPicker("界面字体", selection: $interfaceFontRaw) {
                        ForEach(ReadBoardInterfaceFont.presets, id: \.key) { preset in
                            Text(preset.title).tag(preset.key)
                        }
                        Divider()
                        ForEach(ReadBoardInterfaceFont.availableFontFamilies, id: \.self) { family in
                            Text(family).font(.custom(family, size: 13)).tag("custom:\(family)")
                        }
                    }
                    settingsPicker("正文字体", selection: $fontRaw) {
                        ForEach(ReadBoardReadingFont.presets, id: \.key) { preset in
                            Text(preset.title).tag(preset.key)
                        }
                        Divider()
                        ForEach(ReadBoardReadingFont.availableFontFamilies, id: \.self) { family in
                            Text(family).font(.custom(family, size: 13)).tag("custom:\(family)")
                        }
                    }
                    settingSlider("正文字号", value: $fontSize, range: 12...32, step: 1, suffix: "")
                    settingSlider("标题字号", value: $titleFontSize, range: 16...36, step: 1, suffix: "")
                    settingSlider("信息字号", value: $metaFontSize, range: 8...28, step: 1, suffix: "")
                    settingSlider("摘要字号", value: $summaryFontSize, range: 8...28, step: 1, suffix: "")
                    settingSlider("行距", value: $lineSpacing, range: 0...20, step: 1, suffix: "")
                    #if os(macOS)
                    settingSlider("内容宽度", value: $contentWidth, range: 600...1200, step: 50, suffix: "")
                    #endif
                    settingSlider(
                        "界面缩放", value: $uiFontScale, range: 0.8...1.6,
                        step: 0.05, suffix: "%", multiplier: 100)
                } header: {
                    settingsSectionHeader("阅读区版面", showsReset: presentation == .settingsPane)
                }

                Section {
                    settingsPicker("列表密度", selection: $density) {
                        Text("舒适").tag("comfortable")
                        Text("紧凑").tag("compact")
                    }
                    settingsToggle("显示来源名", isOn: $showSource)
                    settingsToggle("显示日期", isOn: $showDate)
                    if showDate {
                        settingsPicker("日期格式", selection: $dateFormat) {
                            Text("绝对（2026-07-25）").tag("absolute")
                            Text("相对（3 小时前）").tag("relative")
                        }
                    }
                    settingsToggle("未读文章标题加粗", isOn: $unreadBold)
                } header: {
                    ReadBoardSettingsSectionTitle("文章列表")
                }
            }
            .formStyle(.grouped)
        }
        #if os(macOS)
        .modifier(ReadBoardReadingSettingsPresentationModifier(
            presentation: presentation))
        #endif
    }

    private func settingsSectionHeader(
        _ title: String,
        showsReset: Bool
    ) -> some View {
        HStack {
            ReadBoardSettingsSectionTitle(title)
            Spacer()
            if showsReset {
                Button("恢复默认", action: restoreDefaults)
                    .buttonStyle(ReadBoardSecondaryButtonStyle())
                    .readBoardSettingsButton(.inline)
                    .textCase(nil)
            }
        }
    }

    private func settingSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String,
        multiplier: Double = 1
    ) -> some View {
        ReadBoardSettingsSliderRow(
            title,
            value: value,
            range: range,
            step: step,
            displayValue: "\(Int(value.wrappedValue * multiplier))\(suffix)")
    }

    private func settingsPicker<Value: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ReadBoardSettingsPickerRow(title, selection: selection, content: content)
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        ReadBoardSettingsToggleRow(title, isOn: isOn)
    }

    private func restoreDefaults() {
        themeRaw = ReadBoardReadingTheme.claude.rawValue
        themeModeRaw = ReadBoardReadingColorMode.system.rawValue
        fontRaw = "system"
        interfaceFontRaw = "system"
        fontSize = 16
        titleFontSize = 24
        metaFontSize = 12
        summaryFontSize = 14
        lineSpacing = 6
        contentWidth = 720
        uiFontScale = 1
        density = "comfortable"
        showSource = true
        showDate = true
        unreadBold = true
        dateFormat = "absolute"
    }
}

#if os(macOS)
private struct ReadBoardReadingSettingsPresentationModifier: ViewModifier {
    let presentation: ReadBoardReadingSettingsPresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        switch presentation {
        case .popover:
            content.frame(width: 480, height: 620)
        case .settingsPane:
            content.frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading)
        }
    }
}
#endif
