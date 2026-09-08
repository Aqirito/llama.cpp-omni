import ComniDomain
import Foundation
import Testing

@testable import ComniRuntime

@Test
func assemblesOneSecondAudioWithOnlyFreshCameraFrames() async throws {
  let assembler = LiveInputAssembler()
  let audio = Data(count: 16_000 * MemoryLayout<Float>.size)
  let firstJPEG = Data([1, 2, 3])
  let secondJPEG = Data([4, 5, 6])

  await assembler.updateCameraFrame(
    jpegData: firstJPEG,
    timestamp: 1
  )
  let first = try await assembler.makeFrame(audioPCM: audio)
  let second = try await assembler.makeFrame(audioPCM: audio)

  await assembler.updateCameraFrame(
    jpegData: secondJPEG,
    timestamp: 2
  )
  let third = try await assembler.makeFrame(
    audioPCM: audio,
    forceListen: true
  )

  #expect(first.jpegFrames == [firstJPEG])
  #expect(first.maxSliceCount == 2)
  #expect(second.jpegFrames.isEmpty)
  #expect(second.maxSliceCount == nil)
  #expect(third.jpegFrames == [secondJPEG])
  #expect(third.forceListen)
}

@Test
func rejectsAudioChunksWithUnexpectedDuration() async {
  let assembler = LiveInputAssembler()

  await #expect(throws: LiveInputAssemblerError.self) {
    try await assembler.makeFrame(audioPCM: Data(count: 4))
  }
}
