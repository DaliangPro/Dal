import AppKit
import CoreImage
import SwiftUI

/// 直接复用应用图标的原始字形，主题只改变墨色，不替换字体。
struct SettingsBrandLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    let width: CGFloat
    var lightOpacity: Double = 0.64
    var darkOpacity: Double = 0.70

    private static let inkRect = CGRect(x: 225, y: 374, width: 816, height: 506)

    var body: some View {
        if let image = Self.logoImage {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: width * Self.inkRect.height / Self.inkRect.width)
                .foregroundStyle(Color.primary)
                .opacity(colorScheme == .dark ? darkOpacity : lightOpacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dal")
        }
    }

    private static let logoImage: NSImage? = {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/BrandLogo.png")
        let url = Bundle.main.url(forResource: "BrandLogo", withExtension: "png") ?? sourceURL
        guard let image = NSImage(contentsOf: url),
              let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = bitmap.cropping(to: inkRect) else { return nil }
        let mask = CIImage(cgImage: cropped)
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.08,
                kCIInputBrightnessKey: -0.04,
                kCIInputSaturationKey: 0
            ])
            .applyingFilter("CIMaskToAlpha")
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let transparent = context.createCGImage(mask, from: mask.extent) else { return nil }
        return NSImage(cgImage: transparent, size: inkRect.size)
    }()
}
