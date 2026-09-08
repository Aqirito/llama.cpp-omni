import AVFoundation
import CoreImage
import CoreMedia
import Foundation

public struct CameraFrame: Sendable {
  public var jpegData: Data
  public var timestamp: TimeInterval

  public init(jpegData: Data, timestamp: TimeInterval) {
    self.jpegData = jpegData
    self.timestamp = timestamp
  }
}

public enum CameraCaptureError: Error, LocalizedError {
  case permissionDenied
  case deviceUnavailable
  case inputCreationFailed
  case cannotAddInput
  case cannotAddOutput
  case jpegEncodingFailed

  public var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Camera access is not authorized."
    case .deviceUnavailable:
      "No camera is available."
    case .inputCreationFailed:
      "The camera input could not be created."
    case .cannotAddInput:
      "The camera input could not be added to the capture session."
    case .cannotAddOutput:
      "The camera output could not be added to the capture session."
    case .jpegEncodingFailed:
      "A camera frame could not be encoded as JPEG."
    }
  }
}

public final class CameraCaptureService: NSObject, @unchecked Sendable {
  public let session = AVCaptureSession()
  public nonisolated let frames: AsyncStream<CameraFrame>

  private let frameContinuation: AsyncStream<CameraFrame>.Continuation
  private let sessionQueue = DispatchQueue(label: "com.comni.camera.session")
  private let outputQueue = DispatchQueue(label: "com.comni.camera.output")
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  private var configuredPosition: AVCaptureDevice.Position?
  private var minimumFrameInterval: TimeInterval = 1
  private var lastFrameTimestamp: TimeInterval = -.infinity

  public override init() {
    let pair = AsyncStream<CameraFrame>.makeStream(
      bufferingPolicy: .bufferingNewest(2)
    )
    frames = pair.stream
    frameContinuation = pair.continuation
    super.init()
  }

  public func start(
    position: AVCaptureDevice.Position = .front,
    framesPerSecond: Double = 1
  ) async throws {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      throw CameraCaptureError.permissionDenied
    }

    minimumFrameInterval = 1 / max(framesPerSecond, 0.1)
    try await withCheckedThrowingContinuation { continuation in
      sessionQueue.async { [self] in
        do {
          if configuredPosition != position {
            try configure(position: position)
          }
          if !session.isRunning {
            session.startRunning()
          }
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  public func stop() async {
    await withCheckedContinuation { continuation in
      sessionQueue.async { [self] in
        if session.isRunning {
          session.stopRunning()
        }
        continuation.resume()
      }
    }
  }

  public func switchCamera() async throws {
    let nextPosition: AVCaptureDevice.Position =
      configuredPosition == .front ? .back : .front
    let wasRunning = session.isRunning
    try await withCheckedThrowingContinuation { continuation in
      sessionQueue.async { [self] in
        do {
          try configure(position: nextPosition)
          if wasRunning, !session.isRunning {
            session.startRunning()
          }
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func configure(position: AVCaptureDevice.Position) throws {
    guard let device = camera(position: position) else {
      throw CameraCaptureError.deviceUnavailable
    }
    guard let input = try? AVCaptureDeviceInput(device: device) else {
      throw CameraCaptureError.inputCreationFailed
    }

    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_32BGRA
    ]
    output.setSampleBufferDelegate(self, queue: outputQueue)

    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .high

    session.inputs.forEach(session.removeInput)
    session.outputs.forEach(session.removeOutput)
    guard session.canAddInput(input) else {
      throw CameraCaptureError.cannotAddInput
    }
    session.addInput(input)
    guard session.canAddOutput(output) else {
      throw CameraCaptureError.cannotAddOutput
    }
    session.addOutput(output)
    configuredPosition = position
    lastFrameTimestamp = -.infinity
  }

  private func camera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external],
      mediaType: .video,
      position: position
    )
    return discovery.devices.first
      ?? AVCaptureDevice.default(for: .video)
  }
}

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
  public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let timestamp = CMTimeGetSeconds(
      CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    )
    guard timestamp - lastFrameTimestamp >= minimumFrameInterval else {
      return
    }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard
      let jpeg = ciContext.jpegRepresentation(
        of: image,
        colorSpace: colorSpace,
        options: [
          kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
            0.82
        ]
      )
    else {
      return
    }

    lastFrameTimestamp = timestamp
    frameContinuation.yield(
      CameraFrame(jpegData: jpeg, timestamp: timestamp)
    )
  }
}
