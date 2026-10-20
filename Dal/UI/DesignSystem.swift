import SwiftUI

// MARK: - Appearance Helper

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Adaptive Color Helper

private func adaptiveColor(
    light: (r: CGFloat, g: CGFloat, b: CGFloat),
    dark: (r: CGFloat, g: CGFloat, b: CGFloat),
    lightAlpha: CGFloat = 1.0,
    darkAlpha: CGFloat = 1.0
) -> Color {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.isDark {
            return NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: darkAlpha)
        }
        return NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: lightAlpha)
    }))
}

// MARK: - Design Tokens

enum TF {

    // MARK: Colors

    /// Warm amber accent: the signature "indicator light" color
    static let amber = adaptiveColor(
        light: (0.76, 0.49, 0.16),
        dark:  (0.83, 0.57, 0.24)
    )

    /// 琥珀实底上的墨色文字（如向导页「去授权」胶囊）：底色明暗恒定，墨色不随主题翻转
    static let amberInk = adaptiveColor(
        light: (0.22, 0.14, 0.02),
        dark:  (0.22, 0.14, 0.02)
    )

    /// Recording active: warm red-orange, urgent but not alarming
    static let recording = adaptiveColor(
        light: (0.84, 0.34, 0.27),
        dark:  (0.87, 0.38, 0.30)
    )

    /// Success: muted warm green
    static let success = adaptiveColor(
        light: (0.35, 0.65, 0.35),
        dark:  (0.42, 0.70, 0.42)
    )

    // MARK: Settings Palette

    static let settingsShell = adaptiveColor(
        light: (0.923, 0.919, 0.911),
        dark:  (0.106, 0.102, 0.094)
    )
    static let settingsCanvas = adaptiveColor(
        light: (0.923, 0.919, 0.911),
        dark:  (0.106, 0.102, 0.094)
    )
    static let settingsSidebarTint = adaptiveColor(
        light: (0.963, 0.959, 0.951),
        dark:  (0.130, 0.124, 0.114)
    )
    static let settingsSidebarRowFill = adaptiveColor(
        light: (0.900, 0.910, 0.920),
        dark:  (0.188, 0.188, 0.188)
    )
    /// 侧栏选中行底色：浅色侧栏已是实色，使用暖灰平色建立清晰层级；
    /// 深色继续用半透白提亮，保持原有明度关系。
    static let settingsSidebarActiveFill = adaptiveColor(
        light: (0.918, 0.914, 0.906),
        dark:  (1.000, 1.000, 1.000),
        lightAlpha: 1.0,
        darkAlpha: 0.12
    )
    /// 实色侧栏悬停底：浅色使用介于侧栏底与选中底之间的暖灰平色，
    /// 保留鼠标跟随感；深色继续用半透白提亮。
    static let settingsSidebarHoverFill = adaptiveColor(
        light: (0.938, 0.935, 0.928),
        dark:  (1.000, 1.000, 1.000),
        lightAlpha: 1.0,
        darkAlpha: 0.07
    )
    /// 毛玻璃调色罩（2026-06-11 用户两轮微调）：深色叠半黑压暗、浅色叠淡白提亮
    static let settingsGlassTint = adaptiveColor(
        light: (1.000, 1.000, 1.000),
        dark:  (0.000, 0.000, 0.000),
        lightAlpha: 0.55,
        darkAlpha: 0.50
    )
    /// 全项目状态灯统一尺寸（2026-06-12 用户拍板）：6pt
    static let settingsStatusDotSize: CGFloat = 6

    /// 设置弹出面板的毛玻璃描边：与侧栏区分层次
    static let settingsGlassPanelStroke = adaptiveColor(
        light: (0.000, 0.000, 0.000),
        dark:  (1.000, 1.000, 1.000),
        lightAlpha: 0.10,
        darkAlpha: 0.14
    )
    /// 毛玻璃面板内段切换的选中块：与导航高亮同款半透白体系，随背景自适应；
    /// 实色区的段切换仍用 settingsSegmentSelectedFill，互不影响
    /// 浅色用纯白实块（浮起、与亮毛玻璃轨道明暗分层）；深色保持半透白
    /// （2026-06-22：原浅色 0.55 半透白叠在亮轨道上分不清选中项）
    static let settingsGlassSegmentSelectedFill = adaptiveColor(
        light: (1.000, 1.000, 1.000),
        dark:  (1.000, 1.000, 1.000),
        lightAlpha: 1.0,
        darkAlpha: 0.16
    )
    static let settingsSidebarRowHoverFill = adaptiveColor(
        light: (0.928, 0.924, 0.916),
        dark:  (0.135, 0.135, 0.135)
    )
    static let settingsSidebarText = adaptiveColor(
        light: (0.325, 0.298, 0.255),
        dark:  (0.620, 0.604, 0.572)
    )
    static let settingsSidebarHoverText = adaptiveColor(
        light: (0.145, 0.123, 0.098),
        dark:  (0.937, 0.929, 0.912)
    )
    static let settingsSidebarSelectionText = adaptiveColor(
        light: (0.145, 0.123, 0.098),
        dark:  (0.937, 0.929, 0.912)
    )
    static let settingsStroke = adaptiveColor(
        light: (0.110, 0.122, 0.149),
        dark:  (1.000, 1.000, 1.000),
        lightAlpha: 0.0,
        darkAlpha: 0.0
    )
    static let settingsBg = adaptiveColor(
        light: (0.923, 0.919, 0.911),
        dark:  (0.106, 0.102, 0.094)
    )
    static let settingsCard = adaptiveColor(
        light: (0.995, 0.994, 0.991),
        dark:  (0.169, 0.161, 0.149)
    )
    // 浅色双色体系（2026-06-13 用户拍板）：浅色只用「暖画布 A=(0.910,0.900,0.868)」+
    // 「白卡 B=(0.988,0.985,0.973)」两色翻转——白卡上的元素用 A 凹陷、画布上的元素用 B 浮起，
    // 中间灰全部收敛。深色值一律不动。
    static let settingsCardAlt = adaptiveColor(
        light: (0.995, 0.994, 0.991),
        dark:  (0.169, 0.161, 0.149)
    )
    /// 统计卡底（2026-06-12 用户发现「不在一个平面」）：浅色用白卡底再染
    /// accent，与白卡同平面浮起；深色保持画布底（与历史渲染逐像素一致）
    static let settingsStatCardBase = adaptiveColor(
        light: (0.995, 0.994, 0.991),
        dark:  (0.169, 0.161, 0.149)
    )
    static let settingsNavActive = adaptiveColor(
        light: (0.918, 0.914, 0.906),
        dark:  (0.122, 0.122, 0.122)
    )
    static let settingsText = adaptiveColor(
        light: (0.145, 0.123, 0.098),
        dark:  (0.937, 0.929, 0.912)
    )
    static let settingsTextSecondary = adaptiveColor(
        light: (0.325, 0.298, 0.255),
        dark:  (0.620, 0.604, 0.572)
    )
    static let settingsTextTertiary = adaptiveColor(
        light: (0.540, 0.500, 0.448),
        dark:  (0.435, 0.420, 0.388)
    )
    /// 左下角毛玻璃设置弹层中，段切换未选中项需要比普通三级文字更清楚；
    /// 只用于语言/外观开关，避免全局弱说明文字一起变重。
    static let settingsGlassSegmentInactiveText = adaptiveColor(
        light: (0.540, 0.500, 0.448),
        dark:  (0.660, 0.640, 0.590)
    )
    static let settingsSelectionFill = adaptiveColor(
        light: (0.923, 0.919, 0.911),
        dark:  (0.122, 0.122, 0.122)
    )
    static let settingsSelectionText = adaptiveColor(
        light: (0.145, 0.123, 0.098),
        dark:  (0.937, 0.929, 0.912)
    )
    // 深色主按钮提亮（2026-07-08 大梁老师：原深藏青底发闷）：字色用与统计卡数字
    // 同款的浅蓝（settingsAccentBlue 深色值），底色为同一浅蓝的低透明度晕染；浅色不变
    static let settingsPrimaryActionFill = adaptiveColor(
        light: (0.875, 0.915, 0.990),
        dark:  (0.470, 0.620, 0.900),
        darkAlpha: 0.16
    )
    static let settingsPrimaryActionText = adaptiveColor(
        light: (0.180, 0.340, 0.650),
        dark:  (0.470, 0.620, 0.900)
    )
    static let settingsSecondaryActionFill = adaptiveColor(
        light: (0.923, 0.919, 0.911),
        dark:  (0.090, 0.090, 0.090)
    )
    /// 下拉触发框底色：比 secondaryActionFill 略浅、又看得出框（2026-06-23 大梁老师两轮微调取中）
    static let settingsDropdownTriggerFill = adaptiveColor(
        light: (0.938, 0.935, 0.928),
        dark:  (0.123, 0.123, 0.123)
    )
    static let settingsGhostActionFill = adaptiveColor(
        light: (0.923, 0.919, 0.911),
        dark:  (0.063, 0.063, 0.063),
        lightAlpha: 0.55,
        darkAlpha: 0.78
    )
    /// 画布上的按钮填充（2026-06-12 用户拍板）：卡上仍用 Secondary/Ghost；坐在画布上
    /// 的按钮改用这两个——浅色比画布暗一档（凹陷，与卡上方向一致），深色沿用现状不变
    static let settingsCanvasActionFill = adaptiveColor(
        light: (0.995, 0.994, 0.991),
        dark:  (0.171, 0.164, 0.152)
    )
    static let settingsCanvasGhostFill = adaptiveColor(
        light: (0.995, 0.994, 0.991),
        dark:  (0.063, 0.063, 0.063),
        lightAlpha: 0.50,
        darkAlpha: 0.78
    )
    /// 切换开关内凹阴影（2026-06-13 用户拍板）：仅段切换/开关轨道用「四周向内凹陷」的暗影
    /// 体现凹槽,替代描边;普通按钮不用;深色 alpha=0,沿用现状不启用
    static let settingsInsetShadow = adaptiveColor(
        light: (0.420, 0.400, 0.370),
        dark:  (0.000, 0.000, 0.000),
        lightAlpha: 0.16,
        darkAlpha: 0.0
    )
    /// 背景板上的切换开关用的重内凹（2026-06-13 用户拍板）：轨道与暖画布同色、无明度差,
    /// 全靠加重的四周内凹凹槽来区分;白卡上的切换开关仍用上面的常规档
    static let settingsInsetShadowStrong = adaptiveColor(
        light: (0.400, 0.380, 0.350),
        dark:  (0.000, 0.000, 0.000),
        lightAlpha: 0.34,
        darkAlpha: 0.0
    )
    static let settingsSuccessFill = adaptiveColor(
        light: (0.875, 0.940, 0.895),
        dark:  (0.063, 0.142, 0.090)
    )
    static let settingsDangerFill = adaptiveColor(
        light: (0.972, 0.890, 0.875),
        dark:  (0.165, 0.078, 0.070)
    )
    static let settingsWarningFill = adaptiveColor(
        light: (0.970, 0.930, 0.830),
        dark:  (0.165, 0.130, 0.070)
    )
    static let settingsAccentGreen = adaptiveColor(
        light: (0.259, 0.620, 0.392),
        dark:  (0.410, 0.760, 0.500)
    )
    /// 状态进按钮成功/失败的整体变色：沿用主按钮「深底+亮字」范式保证对比度，
    /// 不得拿点缀用的亮色 accent 当大面积底色（2026-06-11 教训）
    static let settingsSuccessActionFill = adaptiveColor(
        light: (0.835, 0.930, 0.870),
        dark:  (0.075, 0.195, 0.120)
    )
    static let settingsSuccessActionText = adaptiveColor(
        light: (0.135, 0.420, 0.255),
        dark:  (0.560, 0.870, 0.640)
    )
    static let settingsDangerActionFill = adaptiveColor(
        light: (0.965, 0.875, 0.860),
        dark:  (0.230, 0.085, 0.075)
    )
    static let settingsDangerActionText = adaptiveColor(
        light: (0.640, 0.235, 0.165),
        dark:  (0.960, 0.560, 0.510)
    )
    static let settingsAccentAmber = adaptiveColor(
        light: (0.820, 0.600, 0.220),
        dark:  (0.900, 0.700, 0.320)
    )
    static let settingsAccentRed = adaptiveColor(
        light: (0.796, 0.337, 0.251),
        dark:  (0.940, 0.450, 0.400)
    )
    static let settingsAccentBlue = adaptiveColor(
        light: (0.290, 0.482, 0.796),
        dark:  (0.470, 0.620, 0.900)
    )
    /// 蓝灰强调（案例素材等中性分类）：原为写死的单值灰，深色模式下提亮保持对比
    static let settingsAccentSlate = adaptiveColor(
        light: (0.471, 0.518, 0.604),
        dark:  (0.560, 0.610, 0.700)
    )
    static let settingsSwitchOnFill = adaptiveColor(
        light: (0.245, 0.455, 0.860),
        dark:  (0.220, 0.415, 0.820)
    )
    /// 开关关态轨道填充：明暗分层（浅色压暗 / 深色提亮）与透明毛玻璃面板区分，
    /// 替代原来"关态毛玻璃与面板一致导致看不清"的设计（2026-06-22）
    static let settingsSwitchOffFill = adaptiveColor(
        light: (0.000, 0.000, 0.000),
        dark:  (1.000, 1.000, 1.000),
        lightAlpha: 0.16,
        darkAlpha: 0.18
    )

    static let settingsAppearanceMenuFill = adaptiveColor(
        light: (1.000, 1.000, 1.000),
        dark:  (0.067, 0.067, 0.067),
        lightAlpha: 0.94
    )
    static let settingsPopoverFill = adaptiveColor(
        light: (1.000, 1.000, 1.000),
        dark:  (0.090, 0.090, 0.090),
        lightAlpha: 0.98
    )
    static let settingsPopoverEdge = adaptiveColor(
        light: (0.110, 0.122, 0.149),
        dark:  (1.000, 1.000, 1.000),
        lightAlpha: 0.08,
        darkAlpha: 0.075
    )
    /// 画布上的段切换轨道（2026-06-14 大梁老师拍板方案 B）：取消内凹阴影后,改用比画布略深半档的
    /// 实色,让轨道自成一块可见的凹槽区域,不靠阴影/描边也能看出是控件
    static let settingsSegmentTrackFill = adaptiveColor(
        light: (0.879, 0.875, 0.867),
        dark:  (0.058, 0.055, 0.050)
    )
    // 浅色选中块用纯白浮在比画布略深的轨道上，靠与轨道的明度差区分选中态
    static let settingsSegmentSelectedFill = adaptiveColor(
        light: (0.995, 0.994, 0.991),
        dark:  (0.190, 0.182, 0.170)
    )

    // MARK: Settings Typography
    // 设置面板字体的单一事实来源：6 个基准值 + 语义别名。
    // 新增字体先看基准值够不够用；别名只为语义保留，不得偏离基准值另起炉灶。

    // 2026-06-12 用户拍板「细体倾斜」：正文与大数字 light，唯按钮/强调保留 medium 撑层级。
    // Body 与 Reading 同值是该实验的结果，语义独立保留，将来可单独再分化。
    static let settingsFontCaption = Font.system(size: 11, weight: .light)
    static let settingsFontMono = Font.system(size: 11, weight: .light, design: .monospaced)
    static let settingsFontReading = Font.system(size: 12, weight: .light)
    static let settingsFontBody = Font.system(size: 12, weight: .light)
    static let settingsFontBodyStrong = Font.system(size: 12, weight: .medium)
    static let settingsFontBodyLarge = Font.system(size: 13, weight: .light)
    static let settingsFontMetric = Font.system(size: 24, weight: .light)

    // 语义别名（与基准同值，便于将来单独调节）
    static let settingsFontMetadata = settingsFontCaption
    static let settingsFontControl = settingsFontCaption
    static let settingsFontSectionTitle = settingsFontBody

    // 侧栏导航（与 BodyLarge 同值别名；13pt 档 2026-06-12 起开放给「主角信息」类正文）
    static let settingsFontNavigation = settingsFontBodyLarge
    static let settingsFontNavigationSelected = Font.system(size: 13, weight: .medium)

    // 图标字体四档（Image(systemName:) 专用，文字不得使用）
    static let settingsFontIconMicro = Font.system(size: 8, weight: .medium)
    static let settingsFontIconSmall = Font.system(size: 9, weight: .medium)
    static let settingsFontIconBody = Font.system(size: 11, weight: .light)
    static let settingsFontIconControl = Font.system(size: 13, weight: .light)
    // 向导页大图标两档（权限行图标 / 翻页箭头），原为就地写死字号
    static let settingsFontIconLarge = Font.system(size: 17, weight: .light)
    static let settingsFontIconHero = Font.system(size: 27, weight: .light)

    // MARK: HUD Typography
    // 悬浮条字体（调试预览窗 HUDDebugPreviewWindow 不在此列）

    static let hudFontLargeTitle = Font.system(size: 17, weight: .semibold)
    static let hudFontTitle = Font.system(size: 14, weight: .semibold)
    static let hudFontMetadata = Font.system(size: 11, weight: .light)

    // MARK: NSFont 镜像
    // AppKit 层（NSTextView/NSTextField 等）专用，与同名 SwiftUI token 同值；改字体须两边同步

    static let settingsNSFontReading = NSFont.systemFont(ofSize: 12, weight: .light)
    static let settingsNSFontBody = NSFont.systemFont(ofSize: 12, weight: .light)
    static let settingsNSFontBodyStrong = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let hudNSFontTitle = NSFont.systemFont(ofSize: 14, weight: .semibold)

    // MARK: Radius

    static let radiusControl: CGFloat = 8
    static let radiusSurface: CGFloat = 12

    // MARK: Settings Metrics

    static let settingsControlHeight: CGFloat = 28
    static let settingsCompactControlHeight: CGFloat = 24
    static let settingsButtonHorizontalPadding: CGFloat = 12
    static let settingsCompactButtonHorizontalPadding: CGFloat = 8
    static let settingsControlCornerRadius: CGFloat = radiusControl

    // MARK: Settings Geometry

    static let settingsPagePadding: CGFloat = 16
    static let settingsModuleSpacing: CGFloat = 16
    static let settingsCardSpacing: CGFloat = 8
    static let settingsPrimaryCardPadding: CGFloat = 16
    static let settingsInnerCardPadding: CGFloat = 12
    static let settingsPrimaryCardCornerRadius: CGFloat = radiusSurface
    static let settingsInnerCardCornerRadius: CGFloat = radiusSurface

    // MARK: Spacing

    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingXL: CGFloat = 24

    // MARK: Legacy Radius Aliases

    static let cornerSM: CGFloat = radiusControl
    static let cornerLG: CGFloat = radiusSurface

    // MARK: Floating Bar

    static let barWidth: CGFloat = 528
    static let barHeight: CGFloat = 40
    static let barFallbackWidth: CGFloat = 432
    static let barFallbackMinWidth: CGFloat = 320
    static let barFallbackHeight: CGFloat = 132
    static let barBottomOffset: CGFloat = 43
    static let barOuterInset: CGFloat = 24

    // MARK: Animation

    static let springGentle = Animation.spring(response: 0.5, dampingFraction: 0.75)
    static let hudVisibility = Animation.spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.12)
    static let hudMorph = Animation.spring(response: 0.32, dampingFraction: 0.90, blendDuration: 0.08)
    static let hudWidthFlow = Animation.spring(response: 0.26, dampingFraction: 0.94, blendDuration: 0.04)
}
