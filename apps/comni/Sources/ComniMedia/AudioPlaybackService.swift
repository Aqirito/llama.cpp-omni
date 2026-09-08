@preconcurrency import AVFoundation
import Foundation

public enum AudioPlaybackError: Error, LocalizedError {
  case invalidSampleRate
  case invalidPCMByteCount
  case bufferCreationFailed

  public var errorDescription: String? {
    switch self {
    case .invalidSampleRate:
      "The output sample rate must be positive."
    case .invalidPCMByteCount:
      "The audio delta is not aligned to float32 samples."
    case .bufferCreationFailed:
      "An audio playback buffer could not be created."
    }
  }
}

public final class AudioPlaybackService: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let queue = DispatchQueue(label: "com.comni.audio.playback")

  private var currentSampleRate: Int?
  private var playerAttached = false

  public init() {}

  public func start(sampleRate: Int = 24_000) throws {
    try queue.sync {
      guard sampleRate > 0 else {
        throw AudioPlaybackError.invalidSampleRate
      }
      if currentSampleRate == sampleRate, engine.isRunning {
        if !player.isPlaying {
          player.play()
        }
        return
      }

      stopLocked()
      guard
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: Double(sampleRate),
          channels: 1,
          interleaved: false
        )
      else {
        throw AudioPlaybackError.invalidSampleRate
      }

      if !playerAttached {
        engine.attach(player)
        playerAttached = true
      }
      engine.connect(player, to: engine.mainMixerNode, format: format)
      engine.prepare()
      try engine.start()
      player.play()
      currentSampleRate = sampleRate
    }
  }

  public func enqueue(_ pcmFloat32: Data, sampleRate: Int = 24_000) throws {
    guard pcmFloat32.count.isMultiple(of: MemoryLayout<Float>.size) else {
      throw AudioPlaybackError.invalidPCMByteCount
    }
    if currentSampleRate != sampleRate || !engine.isRunning {
      try start(sampleRate: sampleRate)
    }

    try queue.sync {
      guard
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: Double(sampleRate),
          channels: 1,
          interleaved: false
        )
      else {
        throw AudioPlaybackError.invalidSampleRate
      }

      let sampleCount = pcmFloat32.count / MemoryLayout<Float>.size
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(sampleCount)
        ),
        let samples = buffer.floatChannelData?.pointee
      else {
        throw AudioPlaybackError.bufferCreationFailed
      }

      buffer.frameLength = AVAudioFrameCount(sampleCount)
      _ = pcmFloat32.copyBytes(
        to: UnsafeMutableBufferPointer(
          start: samples,
          count: sampleCount
        )
      )
      player.scheduleBuffer(buffer)
      if !player.isPlaying {
        player.play()
      }
    }
  }

  public func stop() {
    queue.sync {
      stopLocked()
    }
  }

  private func stopLocked() {
    if player.isPlaying {
      player.stop()
    }
    player.reset()
    if engine.isRunning {
      engine.stop()
    }
    currentSampleRate = nil
  }
}
