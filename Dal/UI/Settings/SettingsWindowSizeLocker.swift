import AppKit

final class SettingsWindowSizeLocker {
    private weak var observedWindow: NSWindow?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var currentLockedContentWidth: CGFloat = 0
    private var lockedLeftEdge: CGFloat?
    private var isApplyingLockedWidth = false

    deinit {
        detachObservers()
    }

    func lock(
        window: NSWindow,
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        minimumContentHeight: CGFloat
    ) {
        currentLockedContentWidth = contentWidth
        attachObserversIfNeeded(to: window)

        let defaultMinimumContentSize = NSSize(
            width: SettingsLayout.windowMinimumContentWidth,
            height: minimumContentHeight
        )
        window.contentMinSize = NSSize(width: contentWidth, height: contentHeight)
        window.contentMaxSize = NSSize(width: contentWidth, height: contentHeight)
        window.minSize = defaultMinimumContentSize
        applyContentSize(
            width: contentWidth,
            height: contentHeight,
            to: window,
            preservingLeftEdge: true
        )
        lockedLeftEdge = window.frame.minX
    }

    private func detachObservers() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        observedWindow = nil
    }

    private func attachObserversIfNeeded(to window: NSWindow) {
        guard observedWindow !== window else { return }

        detachObservers()
        observedWindow = window

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            enforceLockedWidthIfNeeded(for: window)
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            let currentContentWidth = window.contentRect(forFrameRect: window.frame).width
            guard abs(currentContentWidth - currentLockedContentWidth) <= 0.5 else { return }
            lockedLeftEdge = window.frame.minX
        }
    }

    private func enforceLockedWidthIfNeeded(for window: NSWindow) {
        guard !isApplyingLockedWidth else { return }

        let currentContentRect = window.contentRect(forFrameRect: window.frame)
        let targetContentWidth = currentLockedContentWidth

        guard abs(currentContentRect.width - targetContentWidth) > 0.5 else {
            lockedLeftEdge = window.frame.minX
            return
        }

        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: targetContentWidth,
                height: currentContentRect.height
            )
        ).size

        var nextFrame = window.frame
        nextFrame.origin.x = lockedLeftEdge ?? nextFrame.minX
        nextFrame.size.width = targetFrameSize.width

        isApplyingLockedWidth = true
        window.setFrame(nextFrame, display: true, animate: false)
        isApplyingLockedWidth = false
        lockedLeftEdge = nextFrame.minX
    }

    private func applyContentSize(
        width targetContentWidth: CGFloat,
        height targetContentHeight: CGFloat,
        to window: NSWindow,
        preservingLeftEdge: Bool
    ) {
        let currentContentRect = window.contentRect(forFrameRect: window.frame)
        guard abs(currentContentRect.width - targetContentWidth) > 0.5
            || abs(currentContentRect.height - targetContentHeight) > 0.5
        else { return }

        let targetContentRect = NSRect(
            x: 0,
            y: 0,
            width: targetContentWidth,
            height: targetContentHeight
        )
        let targetFrameSize = window.frameRect(forContentRect: targetContentRect).size

        var nextFrame = window.frame
        let topEdge = nextFrame.maxY

        nextFrame.size.width = targetFrameSize.width
        nextFrame.size.height = targetFrameSize.height

        if preservingLeftEdge {
            nextFrame.origin.y = topEdge - nextFrame.size.height
        }

        window.setFrame(nextFrame, display: true, animate: false)
    }
}
