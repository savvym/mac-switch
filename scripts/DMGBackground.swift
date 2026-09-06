import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Expected output PNG path") }
for scale in [1, 2] {
  let image = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 400 * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
  let transform = NSAffineTransform()
  transform.scale(by: CGFloat(scale))
  transform.concat()
  NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
  NSRect(x: 0, y: 0, width: 640, height: 400).fill()

  func text(
    _ value: String, at point: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight
  ) {
    (value as NSString).draw(
      at: point,
      withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
      ])
  }
  let ink = NSColor(calibratedWhite: 0.15, alpha: 1)
  let secondary = NSColor(calibratedWhite: 0.40, alpha: 1)
  text("MAC Switch", at: NSPoint(x: 40, y: 320), size: 30, color: ink, weight: .semibold)
  text(
    "Apple Silicon + Intel", at: NSPoint(x: 40, y: 296), size: 13, color: secondary,
    weight: .regular)
  let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: 34, weight: .medium))!
    .withSymbolConfiguration(
      .init(paletteColors: [NSColor(calibratedRed: 0.10, green: 0.49, blue: 0.46, alpha: 1)]))!
  arrow.draw(in: NSRect(x: 296, y: 180, width: 48, height: 36))
  let instruction = "拖入 Applications 安装"
  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 16), .foregroundColor: secondary,
  ]
  let width = (instruction as NSString).size(withAttributes: attributes).width
  (instruction as NSString).draw(
    at: NSPoint(x: (640 - width) / 2, y: 44), withAttributes: attributes)
  NSGraphicsContext.restoreGraphicsState()
  let base = URL(fileURLWithPath: CommandLine.arguments[1])
  let output =
    scale == 1 ? base : URL(fileURLWithPath: base.deletingPathExtension().path + "@2x.png")
  try image.representation(using: .png, properties: [:])!.write(to: output)
}
