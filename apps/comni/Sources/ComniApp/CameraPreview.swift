import AVFoundation
import AppKit
import SwiftUI

struct CameraPreview: NSViewRepresentable {
  var session: AVCaptureSession
  var mirrored: Bool

  func makeNSView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    updateMirroring(view.previewLayer)
    return view
  }

  func updateNSView(_ nsView: PreviewView, context: Context) {
    nsView.previewLayer.session = session
    updateMirroring(nsView.previewLayer)
  }

  private func updateMirroring(_ layer: AVCaptureVideoPreviewLayer) {
    guard let connection = layer.connection else {
      return
    }
    connection.automaticallyAdjustsVideoMirroring = false
    connection.isVideoMirrored = mirrored
  }
}

final class PreviewView: NSView {
  let previewLayer = AVCaptureVideoPreviewLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = previewLayer
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    previewLayer.frame = bounds
  }
}
