import AVFoundation
import ComniDomain

public enum MediaPermission: String, Sendable {
  case notDetermined
  case denied
  case restricted
  case authorized
}

public struct MediaAuthorization: Sendable {
  public init() {}

  public func microphonePermission() -> MediaPermission {
    permission(for: .audio)
  }

  public func cameraPermission() -> MediaPermission {
    permission(for: .video)
  }

  public func requestMicrophone() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  public func requestCamera() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .video)
  }

  private func permission(for mediaType: AVMediaType) -> MediaPermission {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .notDetermined:
      .notDetermined
    case .denied:
      .denied
    case .restricted:
      .restricted
    case .authorized:
      .authorized
    @unknown default:
      .denied
    }
  }
}
