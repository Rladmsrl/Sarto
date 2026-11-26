import AppKit
import PrismDesign

/// Manages runtime macOS Dock and app-switcher icon switching across the bundled
/// optical-palette icon variants without modifying the signed `.app` bundle on disk.
@MainActor
enum SartoAppIconManager {
    private static let defaultsKey = "dev.sarto.pref.appIconStyle"

    static func savedStyle() -> PrismAppIconStyle {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let style = PrismAppIconStyle.fromPersistedRawValue(raw) {
            return style
        }
        return .defaultStyle
    }

    static func image(for style: PrismAppIconStyle) -> NSImage? {
        guard let source = Bundle.main.image(forResource: NSImage.Name(style.assetName))
            ?? NSImage(named: NSImage.Name(style.assetName))
        else {
            return nil
        }
        // Materialize a fresh CGImage-backed NSImage so AppKit always pushes a new bitmap
        // to the macOS Dock server instead of reusing a cached catalog reference or stale Dock icon.
        var proposed = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        if let cgImage = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return NSImage(cgImage: cgImage, size: NSSize(width: 512, height: 512))
        }
        return source.copy() as? NSImage ?? source
    }

    static func apply(_ style: PrismAppIconStyle) {
        NSApp.dockTile.contentView = nil
        if let rendered = image(for: style) {
            NSApp.applicationIconImage = rendered
        } else {
            NSApp.applicationIconImage = nil
        }
        NSApp.dockTile.display()
    }

    static func applySavedFromDefaults() {
        apply(savedStyle())
    }
}
