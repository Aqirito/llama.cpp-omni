import AppKit
import SwiftUI

struct BrandIcon: View {
  var size: CGFloat

  var body: some View {
    Image(nsImage: NSApplication.shared.applicationIconImage)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
  }
}

struct MenuBarBrandIcon: View {
  var body: some View {
    Group {
      if let image = templateImage {
        Image(nsImage: image)
      } else {
        Image(systemName: "waveform.circle")
      }
    }
    .frame(width: 18, height: 18)
    .accessibilityLabel("Comni")
  }

  private var templateImage: NSImage? {
    guard
      let url = Bundle.main.url(
        forResource: "Comni-menubar",
        withExtension: "png"
      ),
      let source = NSImage(contentsOf: url),
      let image = source.copy() as? NSImage
    else {
      return nil
    }
    image.isTemplate = true
    image.size = NSSize(width: 18, height: 18)
    return image
  }
}
