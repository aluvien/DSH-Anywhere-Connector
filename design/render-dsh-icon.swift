import CoreGraphics
import Foundation
import ImageIO

let side = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
guard let context = CGContext(
  data: nil,
  width: side,
  height: side,
  bitsPerComponent: 8,
  bytesPerRow: side * 4,
  space: colorSpace,
  bitmapInfo: bitmapInfo
) else { fatalError("Unable to create bitmap context") }

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.translateBy(x: 0, y: CGFloat(side))
context.scaleBy(x: 1, y: -1)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

let backgroundColors = [
  color(0.11, 0.18, 0.42),
  color(0.06, 0.10, 0.27),
  color(0.02, 0.03, 0.12),
] as CFArray
let backgroundGradient = CGGradient(colorsSpace: colorSpace, colors: backgroundColors, locations: [0, 0.58, 1])!
context.drawRadialGradient(
  backgroundGradient,
  startCenter: CGPoint(x: 500, y: 320),
  startRadius: 40,
  endCenter: CGPoint(x: 500, y: 500),
  endRadius: 820,
  options: [.drawsAfterEndLocation]
)

let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 168))
shield.addLine(to: CGPoint(x: 756, y: 260))
shield.addLine(to: CGPoint(x: 756, y: 474))
shield.addCurve(to: CGPoint(x: 512, y: 856), control1: CGPoint(x: 756, y: 643), control2: CGPoint(x: 653, y: 770))
shield.addCurve(to: CGPoint(x: 268, y: 474), control1: CGPoint(x: 371, y: 770), control2: CGPoint(x: 268, y: 643))
shield.addLine(to: CGPoint(x: 268, y: 260))
shield.closeSubpath()

context.saveGState()
context.addPath(shield)
context.setShadow(offset: CGSize(width: 0, height: 16), blur: 24, color: color(0, 0, 0, 0.46))
context.setFillColor(color(0.08, 0.15, 0.42))
context.fillPath()
context.restoreGState()

let shieldColors = [color(0.18, 0.30, 0.67), color(0.09, 0.16, 0.43), color(0.05, 0.09, 0.26)] as CFArray
let shieldGradient = CGGradient(colorsSpace: colorSpace, colors: shieldColors, locations: [0, 0.55, 1])!
context.saveGState()
context.addPath(shield)
context.clip()
context.drawLinearGradient(shieldGradient, start: CGPoint(x: 240, y: 180), end: CGPoint(x: 780, y: 850), options: [])
context.restoreGState()
context.addPath(shield)
context.setStrokeColor(color(0.24, 0.35, 0.82))
context.setLineWidth(10)
context.strokePath()

func stroke(_ path: CGPath, color: CGColor, width: CGFloat) {
  context.addPath(path)
  context.setStrokeColor(color)
  context.setLineWidth(width)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  context.strokePath()
}

let arch = CGMutablePath()
arch.move(to: CGPoint(x: 338, y: 522))
arch.addCurve(to: CGPoint(x: 686, y: 522), control1: CGPoint(x: 338, y: 399), control2: CGPoint(x: 686, y: 399))
stroke(arch, color: color(0.31, 0.81, 1), width: 58)

let bridge = CGMutablePath()
bridge.move(to: CGPoint(x: 338, y: 522))
bridge.addLine(to: CGPoint(x: 686, y: 522))
stroke(bridge, color: color(0.45, 0.59, 1), width: 58)

func circle(center: CGPoint, radius: CGFloat, fill: CGColor, stroke: CGColor, lineWidth: CGFloat) {
  let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
  context.setFillColor(fill)
  context.setStrokeColor(stroke)
  context.setLineWidth(lineWidth)
  context.fillEllipse(in: rect)
  context.strokeEllipse(in: rect)
}

circle(center: CGPoint(x: 338, y: 522), radius: 45, fill: color(0.02, 0.08, 0.22), stroke: color(0.41, 0.94, 1), lineWidth: 14)
circle(center: CGPoint(x: 686, y: 522), radius: 45, fill: color(0.07, 0.06, 0.22), stroke: color(0.64, 0.49, 1), lineWidth: 14)
circle(center: CGPoint(x: 338, y: 522), radius: 13, fill: color(0.84, 0.98, 1), stroke: color(0.84, 0.98, 1), lineWidth: 0)
circle(center: CGPoint(x: 686, y: 522), radius: 13, fill: color(0.94, 0.90, 1), stroke: color(0.94, 0.90, 1), lineWidth: 0)

let spine = CGMutablePath()
spine.move(to: CGPoint(x: 512, y: 350))
spine.addLine(to: CGPoint(x: 512, y: 694))
stroke(spine, color: color(0.70, 0.80, 1), width: 16)
circle(center: CGPoint(x: 512, y: 522), radius: 27, fill: color(0.91, 0.98, 1), stroke: color(0.31, 0.72, 1), lineWidth: 10)

guard let image = context.makeImage() else { fatalError("Unable to create image") }
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dsh-anywhere-icon.png")
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
  fatalError("Unable to create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write PNG") }
