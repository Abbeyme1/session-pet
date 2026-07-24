import SwiftUI
import AppKit

/// Renders the idle-state PetIcon into a full macOS .iconset (all sizes
/// iconutil needs) for use as the real app icon (Finder/Dock/About), as
/// opposed to IconAnimator's tiny animated menu-bar-label frames. Run via
/// `swift run SessionPet -- --export-app-icon`, then convert with:
///   iconutil -c icns AppIcon.iconset
@MainActor
func exportAppIconSet() {
    let sizes: [(px: Int, name: String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"),
        (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]
    let dir = ("~/Desktop/test/session-pet/app/AppIcon.iconset" as NSString).expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    for (px, name) in sizes {
        let s = CGFloat(px)
        // Slight inset (matches typical macOS app-icon padding) so the
        // shape doesn't collide with the Dock's rounded-square edge/shadow.
        let inset = s * 0.08
        // forceDark: true — the app icon is a fixed brand asset, not a live
        // appearance-tracking view; without this it hit the same dynamic-
        // color-doesn't-resolve-in-ImageRenderer bug as the menu bar icon.
        let view = PetIcon(state: "idle", size: s - inset * 2, forceDark: true)
            .frame(width: s, height: s)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = false
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { continue }
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    print("Exported iconset to \(dir)")
}

/// Debug-only: dumps the exact render IconAnimator produces for the menu
/// bar icon (same size/scale/appearance-wrapping) to disk, so it can be
/// inspected directly without going through NSStatusItem/menu bar chrome.
@MainActor
func exportMenuBarIconDebug() {
    let size: CGFloat = 18
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let view = PetIcon(state: "idle", size: size, phase: .resting, forceDark: isDark)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    renderer.isOpaque = false

    let nsImage = renderer.nsImage
    print("NSApp.effectiveAppearance.name = \(NSApp.effectiveAppearance.name.rawValue), forceDark = \(isDark)")
    guard let nsImage,
          let tiff = nsImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("render failed")
        return
    }
    let path = "/tmp/menubar_icon_debug.png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}
