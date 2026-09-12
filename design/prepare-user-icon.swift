import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count >= 3 else {
  fatalError("Usage: prepare-user-icon.swift input.png output.png")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
  fatalError("Unable to load input image")
}

let side = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
  data: nil,
  width: side,
  height: side,
  bitsPerComponent: 8,
  bytesPerRow: side * 4,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Unable to create bitmap context") }

// App Store icons should be opaque. The supplied artwork has transparent
// corners, so flatten it onto a matching deep-space background before export.
context.setFillColor(CGColor(red: 0.02, green: 0.05, blue: 0.13, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))
context.interpolationQuality = .high
context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: side, height: side))

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
  fatalError("Unable to create output PNG")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write output PNG") }
