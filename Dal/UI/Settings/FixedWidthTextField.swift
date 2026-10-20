import SwiftUI
import AppKit

// MARK: - Shared Style

private enum SettingsFieldStyle {
    static let textColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.94, green: 0.948, blue: 0.966, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    }
    static let placeholderColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.53, green: 0.58, blue: 0.65, alpha: 1)
            : NSColor(srgbRed: 0.42, green: 0.42, blue: 0.42, alpha: 1)
    }
    static let cursorColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.94, green: 0.948, blue: 0.966, alpha: 1)
            : NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1)
    }
    static let textFont = TF.settingsNSFontBody
    static let placeholderFont = TF.settingsNSFontBody

    /// Configure a bare NSTextField: transparent, no border, just text editing.
    static func applyCommon(to field: NSTextField, placeholder: String, alignment: NSTextAlignment) {
        // Prevent cursor from changing outside visible bounds
        field.wantsLayer = true
        field.layer?.masksToBounds = true
        field.font = textFont
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.textColor = textColor
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byTruncatingTail
        field.alignment = alignment

        applyPlaceholder(to: field, placeholder: placeholder, alignment: alignment)

        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// 占位符带样式应用（makeNSView 与 updateNSView 共用——
    /// 占位符会随加载/状态变化更新，仅在创建时设置会显示过期内容）
    static func applyPlaceholder(to field: NSTextField, placeholder: String, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: placeholderFont,
                .paragraphStyle: style,
            ]
        )
    }
}

private class SettingsTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(for: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate anObject: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: adjustedRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: anObject,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate anObject: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: adjustedRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: anObject,
            start: selStart,
            length: selLength
        )
    }

    override func drawInterior(withFrame rect: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: adjustedRect(for: rect), in: controlView)
    }

    private func adjustedRect(for rect: NSRect) -> NSRect {
        guard let font else { return rect }
        let textHeight = ceil(font.ascender - font.descender)
        let verticalInset = max(0, floor((rect.height - textHeight) / 2))
        return rect.insetBy(dx: 0, dy: verticalInset)
    }
}

private class SettingsSecureTextFieldCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(for: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate anObject: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: adjustedRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: anObject,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate anObject: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: adjustedRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: anObject,
            start: selStart,
            length: selLength
        )
    }

    override func drawInterior(withFrame rect: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: adjustedRect(for: rect), in: controlView)
    }

    private func adjustedRect(for rect: NSRect) -> NSRect {
        guard let font else { return rect }
        let textHeight = ceil(font.ascender - font.descender)
        let verticalInset = max(0, floor((rect.height - textHeight) / 2))
        return rect.insetBy(dx: 0, dy: verticalInset)
    }
}

// MARK: - NSTextField subclass (cursor color + no intrinsic width)

private class SettingsNSTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { SettingsTextFieldCell.self }
        set { }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
    override func resetCursorRects() {
        // Only show I-beam cursor when the field is editable and visible
        if isEditable && !isHidden && alphaValue > 0 {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditable && !isHidden && alphaValue > 0 else { return nil }
        return super.hitTest(point)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = SettingsFieldStyle.cursorColor
        }
        return result
    }
}

private class SettingsNSSecureTextField: NSSecureTextField {
    override class var cellClass: AnyClass? {
        get { SettingsSecureTextFieldCell.self }
        set { }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
    override func resetCursorRects() {
        if isEditable && !isHidden && alphaValue > 0 {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditable && !isHidden && alphaValue > 0 else { return nil }
        return super.hitTest(point)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = SettingsFieldStyle.cursorColor
        }
        return result
    }
}

// MARK: - SwiftUI Wrappers (bare text field, no visual styling)

/// Bare NSTextField wrapper. Visual styling is applied by the caller.
struct FixedWidthTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var alignment: NSTextAlignment = .left

    func makeNSView(context: Context) -> NSTextField {
        let field = SettingsNSTextField()
        SettingsFieldStyle.applyCommon(to: field, placeholder: placeholder, alignment: alignment)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if nsView.alignment != alignment { nsView.alignment = alignment }
        if nsView.placeholderAttributedString?.string != placeholder {
            SettingsFieldStyle.applyPlaceholder(to: nsView, placeholder: placeholder, alignment: alignment)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Bare NSSecureTextField wrapper.
struct FixedWidthSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var alignment: NSTextAlignment = .left

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = SettingsNSSecureTextField()
        SettingsFieldStyle.applyCommon(to: field, placeholder: placeholder, alignment: alignment)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if nsView.alignment != alignment { nsView.alignment = alignment }
        if nsView.placeholderAttributedString?.string != placeholder {
            SettingsFieldStyle.applyPlaceholder(to: nsView, placeholder: placeholder, alignment: alignment)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
