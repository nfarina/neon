// Turn a square piece of artwork into eyes/Neon.icns.
//
//   swift eyes/icon.swift ~/Downloads/whatever.png
//
// Image generators produce a full-bleed square; macOS wants something quite
// specific, and getting it wrong is the difference between an icon that sits
// correctly in the Dock and one that looks like a sticker somebody added.
//
// The macOS 11+ grid: on a 1024 canvas the icon body is 824×824 — so roughly
// 20% of the canvas is deliberately empty — nudged up slightly to leave room
// for a soft shadow beneath. The corner is Apple's *continuous* curve, not a
// circular arc; a plain rounded rectangle reads subtly wrong next to every
// other icon on the machine. SwiftUI knows the real shape, so we borrow it
// rather than approximating a superellipse by hand.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: swift eyes/icon.swift <artwork.png> [output.icns]")
    exit(1)
}
let sourcePath = (args[1] as NSString).expandingTildeInPath
guard let source = NSImage(contentsOfFile: sourcePath) else {
    print("could not read \(sourcePath)")
    exit(1)
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let icnsURL = args.count > 2
    ? URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    : here.appendingPathComponent("Neon.icns")
let iconsetURL = here.appendingPathComponent("Neon.iconset")

// Apple's proportions, expressed against the 1024 canvas.
let canvas: CGFloat = 1024
let body: CGFloat = 824          // the visible rounded square
let cornerRadius: CGFloat = 185.4  // continuous corner on an 824 body
let shadowOffset: CGFloat = 10     // how far the body sits above centre
let shadowBlur: CGFloat = 20

/// One PNG at one size, drawn at full 1024 fidelity and downsampled, so small
/// sizes get the benefit of the whole image rather than a blocky mask.
func render(size: CGFloat) -> Data? {
    let scale = size / canvas
    guard let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)

    // The body sits centred horizontally and a touch above centre vertically;
    // the gap it leaves at the bottom is where the shadow goes.
    let inset = (canvas - body) / 2
    let bodyRect = CGRect(x: inset, y: inset + shadowOffset, width: body, height: body)

    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let path = shape.path(in: bodyRect).cgPath

    // Shadow first, cast by an opaque fill of the same shape, then the
    // artwork clipped into it. Drawing the artwork with a shadow directly
    // would shadow every bright pixel inside the icon too.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -shadowOffset),
                  blur: shadowBlur,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    var rect = CGRect(x: 0, y: 0, width: source.size.width, height: source.size.height)
    if let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
        // Artwork is square; fill the body exactly.
        ctx.draw(cg, in: bodyRect)
    }
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

// The set iconutil expects. Each logical size appears twice (@1x and @2x)
// because the Dock, Finder columns, Spotlight and Get Info all pick different
// ones, and a missing entry silently falls back to something blurrier.
let entries: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for entry in entries {
    guard let data = render(size: entry.px) else {
        print("failed rendering \(entry.name)"); exit(1)
    }
    try! data.write(to: iconsetURL.appendingPathComponent(entry.name))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    print("iconutil failed"); exit(1)
}
// The .iconset is a build artifact of this script; the .icns is the thing
// build.sh copies into the bundle.
try? FileManager.default.removeItem(at: iconsetURL)

let bytes = (try? Data(contentsOf: icnsURL).count) ?? 0
print("wrote \(icnsURL.path) — \(bytes / 1024) KB from \(sourcePath)")
