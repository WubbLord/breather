import AppKit

let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
let names = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
for (size, name) in names {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let cg = context.cgContext; cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let bg = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 214, yRadius: 214)
    NSGradient(starting: NSColor(calibratedRed: 0.26, green: 0.52, blue: 0.45, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.30, alpha: 1))!.draw(in: bg, angle: -90)
    NSColor.white.withAlphaComponent(0.17).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 201, y: 201, width: 622, height: 622)); ring.lineWidth = 10; ring.stroke()
    let leaf = NSBezierPath()
    leaf.move(to: NSPoint(x: 345, y: 342))
    leaf.curve(to: NSPoint(x: 710, y: 710), controlPoint1: NSPoint(x: 279, y: 558), controlPoint2: NSPoint(x: 535, y: 711))
    leaf.curve(to: NSPoint(x: 345, y: 342), controlPoint1: NSPoint(x: 716, y: 468), controlPoint2: NSPoint(x: 540, y: 306))
    NSColor(calibratedRed: 0.90, green: 0.96, blue: 0.89, alpha: 1).setFill(); leaf.fill()
    let stem = NSBezierPath(); stem.move(to: NSPoint(x: 309, y: 304)); stem.curve(to: NSPoint(x: 625, y: 629), controlPoint1: NSPoint(x: 381, y: 430), controlPoint2: NSPoint(x: 471, y: 494)); stem.lineWidth = 15; stem.lineCapStyle = .round
    NSColor(calibratedRed: 0.27, green: 0.51, blue: 0.43, alpha: 1).setStroke(); stem.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
}
// ICNS permits PNG payloads; package the generated sizes without a system conversion service.
var chunks = Data()
func be32(_ value: Int) -> Data { var word = UInt32(value).bigEndian; return withUnsafeBytes(of: &word) { Data($0) } }
for (type, name) in [("icp4", "icon_16x16"), ("icp5", "icon_32x32"), ("icp6", "icon_32x32@2x"), ("ic07", "icon_128x128"), ("ic08", "icon_256x256"), ("ic09", "icon_512x512"), ("ic10", "icon_512x512@2x"), ("ic11", "icon_16x16@2x"), ("ic12", "icon_32x32@2x"), ("ic13", "icon_128x128@2x"), ("ic14", "icon_256x256@2x")] {
    let png = try Data(contentsOf: URL(fileURLWithPath: folder + "/" + name + ".png"))
    chunks.append(type.data(using: .ascii)!); chunks.append(be32(png.count + 8)); chunks.append(png)
}
var icns = "icns".data(using: .ascii)!; icns.append(be32(chunks.count + 8)); icns.append(chunks)
try icns.write(to: URL(fileURLWithPath: folder).deletingLastPathComponent().appendingPathComponent("Breather.icns"))
