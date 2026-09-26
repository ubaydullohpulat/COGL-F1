// Renders the app icon into an .iconset folder: swift scripts/make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
  let s = CGFloat(px)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let inset = s * 0.1
  let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
  NSGradient(colors: [NSColor(red: 0.07, green: 0.16, blue: 0.42, alpha: 1), NSColor(red: 0.05, green: 0.55, blue: 0.62, alpha: 1)])!
    .draw(in: bg, angle: -50)

  func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
  let hist: [(CGFloat, CGFloat)] = [(0.12, 0.40), (0.2, 0.52), (0.28, 0.44), (0.36, 0.58), (0.44, 0.5), (0.52, 0.62)]
  let fc: [(CGFloat, CGFloat)] = [(0.52, 0.62), (0.62, 0.56), (0.72, 0.68), (0.82, 0.62), (0.9, 0.72)]
  // Uncertainty band around the forecast.
  let band = NSBezierPath()
  band.move(to: pt(0.52, 0.62))
  for (i, p) in fc.enumerated().dropFirst() { band.line(to: pt(p.0, p.1 + 0.05 + CGFloat(i) * 0.03)) }
  for (i, p) in fc.enumerated().reversed() { band.line(to: pt(p.0, p.1 - (i == 0 ? 0 : 0.05 + CGFloat(i) * 0.03))) }
  band.close()
  NSColor(white: 1, alpha: 0.22).setFill()
  band.fill()

  let line = NSBezierPath()
  line.lineWidth = s * 0.035
  line.lineCapStyle = .round
  line.lineJoinStyle = .round
  line.move(to: pt(hist[0].0, hist[0].1))
  for p in hist.dropFirst() { line.line(to: pt(p.0, p.1)) }
  NSColor.white.setStroke()
  line.stroke()

  let f = NSBezierPath()
  f.lineWidth = s * 0.035
  f.lineCapStyle = .round
  f.lineJoinStyle = .round
  f.move(to: pt(fc[0].0, fc[0].1))
  for p in fc.dropFirst() { f.line(to: pt(p.0, p.1)) }
  NSColor(red: 0.55, green: 1.0, blue: 0.85, alpha: 1).setStroke()
  f.stroke()

  let dot = NSBezierPath(ovalIn: NSRect(origin: pt(0.52, 0.62), size: .zero).insetBy(dx: -s * 0.03, dy: -s * 0.03))
  NSColor.white.setFill()
  dot.fill()

  let label = "F1" as NSString
  let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: s * 0.16, weight: .heavy),
    .foregroundColor: NSColor(white: 1, alpha: 0.9),
  ]
  label.draw(at: pt(0.12, 0.1), withAttributes: attrs)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
  try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
  try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
