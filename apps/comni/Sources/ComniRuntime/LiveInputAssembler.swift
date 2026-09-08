import ComniDomain
import Foundation

public enum LiveInputAssemblerError: Error, LocalizedError {
  case invalidAudioByteCount(expected: Int, actual: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidAudioByteCount(let expected, let actual):
      "Expected \(expected) bytes of float32 PCM, received \(actual)."
    }
  }
}

public actor LiveInputAssembler {
  private let samplesPerChunk: Int
  private let maxSliceCount: Int?
  private var latestJPEG: Data?
  private var latestJPEGTimestamp: TimeInterval = -.infinity
  private var lastSentJPEGTimestamp: TimeInterval = -.infinity

  public init(
    sampleRate: Int = 16_000,
    chunkDuration: Duration = .seconds(1),
    maxSliceCount: Int? = 2
  ) {
    let duration = Self.durationSeconds(chunkDuration)
    samplesPerChunk = max(1, Int(Double(sampleRate) * duration))
    self.maxSliceCount = maxSliceCount
  }

  public func updateCameraFrame(
    jpegData: Data,
    timestamp: TimeInterval
  ) {
    guard timestamp > latestJPEGTimestamp else {
      return
    }
    latestJPEG = jpegData
    latestJPEGTimestamp = timestamp
  }

  public func makeFrame(
    audioPCM: Data,
    forceListen: Bool = false
  ) throws -> LiveInputFrame {
    let expectedByteCount = samplesPerChunk * MemoryLayout<Float>.size
    guard audioPCM.count == expectedByteCount else {
      throw LiveInputAssemblerError.invalidAudioByteCount(
        expected: expectedByteCount,
        actual: audioPCM.count
      )
    }

    var jpegFrames: [Data] = []
    if let latestJPEG,
      latestJPEGTimestamp > lastSentJPEGTimestamp
    {
      jpegFrames = [latestJPEG]
      lastSentJPEGTimestamp = latestJPEGTimestamp
    }
    return LiveInputFrame(
      audioPCM: audioPCM,
      jpegFrames: jpegFrames,
      maxSliceCount: jpegFrames.isEmpty ? nil : maxSliceCount,
      forceListen: forceListen
    )
  }

  public func reset() {
    latestJPEG = nil
    latestJPEGTimestamp = -.infinity
    lastSentJPEGTimestamp = -.infinity
  }

  private static func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }
}
