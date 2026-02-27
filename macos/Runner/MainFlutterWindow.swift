import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Launch at 80% x 90% of the visible screen area (menu bar + Dock
    // excluded), centered on screen.
    if let work = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
      let targetWidth = (work.width * 0.80).rounded(.down)
      let targetHeight = (work.height * 0.90).rounded(.down)
      let targetX = work.origin.x + (work.width - targetWidth) / 2
      let targetY = work.origin.y + (work.height - targetHeight) / 2

      let frame = NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)
      self.setFrame(frame, display: true)
    }

    super.awakeFromNib()
  }
}
