@preconcurrency import AVFoundation
import Foundation

public struct AudioChunk: Sendable {
  public var pcmFloat32: Data
  public var sampleRate: Int
  public var sampleCount: Int

  public init(pcmFloat32: Data, sampleRate: Int, sampleCount: Int) {
    self.pcmFloat32 = pcmFloat32
    self.sampleRate = sampleRate
    self.sampleCount = sampleCount
  }
}

public enum AudioCaptureError: Error, LocalizedError {
  case permissionDenied
  case inputUnavailable
  case formatConversionUnavailable

  public var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Microphone access is not authorized."
    case .inputUnavailable:
      "No usable microphone input is available."
    case .formatConversionUnavailable:
      "The microphone audio format cannot be converted to 16 kHz mono."
    }
  }
}

public final class AudioCaptureService: @unchecked Sendable {
  public nonisolated let chunks: AsyncStream<AudioChunk>

  private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
  private let engine = AVAudioEngine()
  private let processingQueue = DispatchQueue(label: "com.comni.audio.capture")
  private let targetSampleRate = 16_000

  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private var pendingPCM = Data()
  private var samplesPerChunk = 16_000
  private var tapInstalled = false

  public init() {
    let pair = AsyncStream<AudioChunk>.makeStream(
      bufferingPolicy: .bufferingNewest(4)
    )
    chunks = pair.stream
    chunkContinuation = pair.continuation
  }

  public func start(
    chunkDuration: Duration = .seconds(1),
    voiceProcessingEnabled: Bool = true
  ) throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw AudioCaptureError.permissionDenied
    }
    guard !tapInstalled else {
      return
    }

    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw AudioCaptureError.inputUnavailable
    }
    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(targetSampleRate),
        channels: 1,
        interleaved: false
      ),
      let converter = AVAudioConverter(
        from: inputFormat,
        to: targetFormat
      )
    else {
      throw AudioCaptureError.formatConversionUnavailable
    }

    if voiceProcessingEnabled {
      try? inputNode.setVoiceProcessingEnabled(true)
    }

    self.targetFormat = targetFormat
    self.converter = converter
    samplesPerChunk = max(
      1,
      Int(
        Double(targetSampleRate)
          * durationSeconds(chunkDuration)
      )
    )
    pendingPCM.removeAll(keepingCapacity: true)

    inputNode.installTap(
      onBus: 0,
      bufferSize: 4096,
      format: inputFormat
    ) { [weak self] buffer, _ in
      guard let self, let copiedBuffer = self.copy(buffer) else {
        return
      }
      let bufferBox = PCMBufferBox(copiedBuffer)
      self.processingQueue.async {
        self.convertAndAppend(bufferBox.buffer)
      }
    }
    tapInstalled = true

    engine.prepare()
    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      tapInstalled = false
      throw error
    }
  }

  public func stop() {
    guard tapInstalled else {
      return
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    tapInstalled = false
    processingQueue.async { [self] in
      pendingPCM.removeAll(keepingCapacity: false)
    }
  }

  private func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let copy = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: buffer.frameLength
      )
    else {
      return nil
    }
    copy.frameLength = buffer.frameLength

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(
      buffer.mutableAudioBufferList
    )
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(
      copy.mutableAudioBufferList
    )
    let bufferCount = min(sourceBuffers.count, destinationBuffers.count)
    for index in 0..<bufferCount {
      let sourceBuffer = sourceBuffers[index]
      let destinationBuffer = destinationBuffers[index]
      guard
        let sourceData = sourceBuffer.mData,
        let destinationData = destinationBuffer.mData
      else {
        continue
      }
      let byteCount = Int(sourceBuffer.mDataByteSize)
      memcpy(destinationData, sourceData, byteCount)
      destinationBuffers[index].mDataByteSize = UInt32(byteCount)
    }
    return copy
  }

  private func convertAndAppend(_ input: AVAudioPCMBuffer) {
    guard let converter, let targetFormat else {
      return
    }
    let ratio = targetFormat.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount(
      ceil(Double(input.frameLength) * ratio)
    )
    guard
      capacity > 0,
      let output = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: capacity
      )
    else {
      return
    }

    let inputBox = ConverterInputBox(input)
    var conversionError: NSError?
    let status = converter.convert(
      to: output,
      error: &conversionError
    ) { _, inputStatus in
      if inputBox.supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      inputBox.supplied = true
      inputStatus.pointee = .haveData
      return inputBox.buffer
    }
    guard
      status != .error,
      conversionError == nil,
      let samples = output.floatChannelData?.pointee
    else {
      return
    }

    pendingPCM.append(
      UnsafeBufferPointer(
        start: samples,
        count: Int(output.frameLength)
      )
    )

    let bytesPerChunk = samplesPerChunk * MemoryLayout<Float>.size
    while pendingPCM.count >= bytesPerChunk {
      let chunk = pendingPCM.prefix(bytesPerChunk)
      chunkContinuation.yield(
        AudioChunk(
          pcmFloat32: Data(chunk),
          sampleRate: targetSampleRate,
          sampleCount: samplesPerChunk
        )
      )
      pendingPCM.removeFirst(bytesPerChunk)
    }
  }

  private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }
}

private final class PCMBufferBox: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer

  init(_ buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }
}

private final class ConverterInputBox: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  var supplied = false

  init(_ buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }
}
