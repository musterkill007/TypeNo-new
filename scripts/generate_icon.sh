#!/bin/bash
set -e

# Generate a simple TypeNo icon using SF Symbols
# Create a temporary Swift script to generate the icon

cat > /tmp/generate_typeno_icon.swift << 'EOF'
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()

// Background gradient
let gradient = NSGradient(colors: [
    NSColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1.0),
    NSColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1.0)
])
gradient?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 135)

// Draw "⌃" text
let text = "⌃"
let font = NSFont.systemFont(ofSize: size * 0.5, weight: .light)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white
]
let textSize = text.size(withAttributes: attrs)
let textRect = NSRect(
    x: (size - textSize.width) / 2,
    y: (size - textSize.height) / 2,
    width: textSize.width,
    height: textSize.height
)
text.draw(in: textRect, withAttributes: attrs)

image.unlockFocus()

// Save as PNG
if let tiffData = image.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    try? pngData.write(to: URL(fileURLWithPath: "/tmp/typeno_icon_1024.png"))
}
EOF

swift /tmp/generate_typeno_icon.swift

# Generate iconset
cd App/TypeNo.iconset

sips -z 16 16 /tmp/typeno_icon_1024.png --out icon_16x16.png
sips -z 32 32 /tmp/typeno_icon_1024.png --out icon_16x16@2x.png
sips -z 32 32 /tmp/typeno_icon_1024.png --out icon_32x32.png
sips -z 64 64 /tmp/typeno_icon_1024.png --out icon_32x32@2x.png
sips -z 128 128 /tmp/typeno_icon_1024.png --out icon_128x128.png
sips -z 256 256 /tmp/typeno_icon_1024.png --out icon_128x128@2x.png
sips -z 256 256 /tmp/typeno_icon_1024.png --out icon_256x256.png
sips -z 512 512 /tmp/typeno_icon_1024.png --out icon_256x256@2x.png
sips -z 512 512 /tmp/typeno_icon_1024.png --out icon_512x512.png
sips -z 1024 1024 /tmp/typeno_icon_1024.png --out icon_512x512@2x.png

cd ../..
iconutil -c icns App/TypeNo.iconset -o App/TypeNo.icns

echo "Icon generated at App/TypeNo.icns"
