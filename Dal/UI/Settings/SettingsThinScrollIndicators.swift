import AppKit
import SwiftUI

extension View {
    func settingsThinScrollIndicators() -> some View {
        background(SettingsScrollViewConfigurator())
    }
}

private struct SettingsScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        scheduleConfigureScrollViews(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleConfigureScrollViews(from: nsView)
    }

    private func scheduleConfigureScrollViews(from view: NSView) {
        let delays: [TimeInterval] = [0, 0.05, 0.2]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                configureScrollViews(from: view)
            }
        }
    }

    private func configureScrollViews(from view: NSView) {
        if let enclosingScrollView = view.enclosingScrollView ?? view.nearestSuperview(of: NSScrollView.self) {
            configure(enclosingScrollView)
        }

        guard let root = view.window?.contentView ?? view.superview else {
            return
        }

        root.descendants(of: NSScrollView.self).forEach(configure)
    }

    private func configure(_ scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .default
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.horizontalScroller?.controlSize = .mini
    }
}

private extension NSView {
    func nearestSuperview<T: NSView>(of type: T.Type) -> T? {
        var candidate = superview
        while let current = candidate {
            if let matched = current as? T {
                return matched
            }
            candidate = current.superview
        }
        return nil
    }

    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            var matches = subview.descendants(of: type)
            if let matched = subview as? T {
                matches.insert(matched, at: 0)
            }
            return matches
        }
    }
}
