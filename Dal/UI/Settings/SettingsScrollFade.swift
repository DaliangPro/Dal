import SwiftUI

enum SettingsScrollFade {
    static let height: CGFloat = 36
    static let contentPadding: CGFloat = 28
    /// 双向渐变用的小幅高度（2026-06-12 用户拍板：上下一致、幅度收敛）
    static let subtleHeight: CGFloat = 22
}

/// 上下对称的滚动渐变：触顶/触底的文字都以同样的小幅度淡出。
/// showsTop/showsBottom 允许调用方按滚动位置动态开关——未滚动时顶部渐隐
/// 不应盖住第一行字（2026-07-08 大梁老师）
private struct SettingsVerticalScrollFadeModifier: ViewModifier {
    let color: Color
    let height: CGFloat
    let showsTop: Bool
    let showsBottom: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if showsTop {
                    LinearGradient(
                        stops: [
                            .init(color: color, location: 0.0),
                            .init(color: color.opacity(0), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottom) {
                if showsBottom {
                    LinearGradient(
                        stops: [
                            .init(color: color.opacity(0), location: 0.0),
                            .init(color: color, location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func settingsVerticalScrollFade(
        color: Color,
        height: CGFloat = SettingsScrollFade.subtleHeight,
        showsTop: Bool = true,
        showsBottom: Bool = true
    ) -> some View {
        modifier(SettingsVerticalScrollFadeModifier(
            color: color,
            height: height,
            showsTop: showsTop,
            showsBottom: showsBottom
        ))
    }
}

private struct SettingsBottomScrollFadeModifier: ViewModifier {
    let color: Color
    let height: CGFloat
    let isVisible: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isVisible {
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(0), location: 0.0),
                        .init(color: color.opacity(0.72), location: 0.62),
                        .init(color: color, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func settingsBottomScrollFade(
        color: Color,
        height: CGFloat = SettingsScrollFade.height,
        isVisible: Bool = true
    ) -> some View {
        modifier(SettingsBottomScrollFadeModifier(color: color, height: height, isVisible: isVisible))
    }
}
