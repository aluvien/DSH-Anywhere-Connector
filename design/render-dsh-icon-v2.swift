import CoreGraphics
import Foundation
import ImageIO

let side = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
  data: nil,
  width: side,
  height: side,
  bitsPerComponent: 8,
  bytesPerRow: side * 4,
  space: space,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Unable to create bitmap context") }

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.translateBy(x: 0, y: CGFloat(side))
context.scaleBy(x: 1, y: -1)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(red: r, green: g, blue: b, alpha: a)
}

let background = CGGradient(
  colorsSpace: space,
  colors: [color(0.22, 0.13, 0.30), color(0.105, 0.06, 0.18), color(0.025, 0.02, 0.055)] as CFArray,
  locations: [0, 0.48, 1]
)!
context.drawRadialGradient(
  background,
  startCenter: CGPoint(x: 500, y: 360),
  startRadius: 20,
  endCenter: CGPoint(x: 500, y: 500),
  endRadius: 820,
  options: [.drawsAfterEndLocation]
)

func stroke(_ path: CGPath, _ strokeColor: CGColor, _ width: CGFloat, shadow: Bool = false) {
  context.saveGState()
  if shadow {
    context.setShadow(offset: .zero, blur: 22, color: color(0, 0, 0, 0.55))
  }
  context.addPath(path)
  context.setStrokeColor(strokeColor)
  context.setLineWidth(width)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  context.strokePath()
  context.restoreGState()
}

func circle(_ center: CGPoint, _ radius: CGFloat, fill: CGColor, outline: CGColor, width: CGFloat) {
  let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
  context.setFillColor(fill)
  context.setStrokeColor(outline)
  context.setLineWidth(width)
  context.fillEllipse(in: rect)
  if width > 0 { context.strokeEllipse(in: rect) }
}

let orbit = CGMutablePath()
orbit.move(to: CGPoint(x: 270, y: 512))
orbit.addCurve(to: CGPoint(x: 512, y: 512), control1: CGPoint(x: 270, y: 330), control2: CGPoint(x: 420, y: 330))
orbit.addCurve(to: CGPoint(x: 754, y: 512), control1: CGPoint(x: 604, y: 694), control2: CGPoint(x: 754, y: 694))
orbit.addCurve(to: CGPoint(x: 512, y: 512), control1: CGPoint(x: 754, y: 330), control2: CGPoint(x: 604, y: 330))
orbit.addCurve(to: CGPoint(x: 270, y: 512), control1: CGPoint(x: 420, y: 694), control2: CGPoint(x: 270, y: 694))
stroke(orbit, color(0.03, 0.02, 0.07), 112, shadow: true)

let leftTop = CGMutablePath()
leftTop.move(to: CGPoint(x: 270, y: 512))
leftTop.addCurve(to: CGPoint(x: 512, y: 512), control1: CGPoint(x: 270, y: 330), control2: CGPoint(x: 420, y: 330))
stroke(leftTop, color(0.47, 0.96, 0.78), 72)

let rightBottom = CGMutablePath()
rightBottom.move(to: CGPoint(x: 512, y: 512))
rightBottom.addCurve(to: CGPoint(x: 754, y: 512), control1: CGPoint(x: 604, y: 694), control2: CGPoint(x: 754, y: 694))
stroke(rightBottom, color(1, 0.42, 0.46), 72)

let rightTop = CGMutablePath()
rightTop.move(to: CGPoint(x: 754, y: 512))
rightTop.addCurve(to: CGPoint(x: 512, y: 512), control1: CGPoint(x: 754, y: 330), control2: CGPoint(x: 604, y: 330))
stroke(rightTop, color(0.56, 0.39, 1), 72)

let leftBottom = CGMutablePath()
leftBottom.move(to: CGPoint(x: 512, y: 512))
leftBottom.addCurve(to: CGPoint(x: 270, y: 512), control1: CGPoint(x: 420, y: 694), control2: CGPoint(x: 270, y: 694))
stroke(leftBottom, color(1, 0.61, 0.38), 72)

let portal = CGMutablePath()
portal.move(to: CGPoint(x: 366, y: 342))
portal.addLine(to: CGPoint(x: 366, y: 682))
portal.move(to: CGPoint(x: 406, y: 350))
portal.addCurve(to: CGPoint(x: 406, y: 674), control1: CGPoint(x: 638, y: 350), control2: CGPoint(x: 638, y: 674))
stroke(portal, color(0.03, 0.02, 0.07), 126, shadow: true)
stroke(portal, color(1, 0.33, 0.50), 92)

circle(CGPoint(x: 270, y: 512), 51, fill: color(0.08, 0.06, 0.15), outline: color(1, 0.61, 0.38), width: 15)
circle(CGPoint(x: 754, y: 512), 51, fill: color(0.07, 0.09, 0.16), outline: color(0.48, 1, 0.82), width: 15)
circle(CGPoint(x: 512, y: 512), 34, fill: color(0.09, 0.06, 0.16), outline: color(0.89, 0.65, 1), width: 13)
circle(CGPoint(x: 270, y: 512), 13, fill: color(1, 0.88, 0.80), outline: color(1, 0.88, 0.80), width: 0)
circle(CGPoint(x: 754, y: 512), 13, fill: color(0.86, 1, 0.94), outline: color(0.86, 1, 0.94), width: 0)
circle(CGPoint(x: 512, y: 512), 10, fill: color(1, 1, 1), outline: color(1, 1, 1), width: 0)

guard let image = context.makeImage() else { fatalError("Unable to create image") }
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dsh-anywhere-icon-v2.png")
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
  fatalError("Unable to create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write PNG") }
