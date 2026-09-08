import Foundation
import Testing

@testable import ComniDomain

@Test
func modelCapabilityRoundTripsThroughJSON() throws {
  let capability = ModelCapability(
    adapter: .miniCPMO,
    interactionModes: [.chat, .voiceLive, .visionLive],
    inputs: [.text, .image, .audio, .video, .camera],
    outputs: [.text, .audio],
    features: [.voiceClone, .proactiveSpeech],
    limits: ModelLimits(
      maxContext: 8192,
      inputAudioSampleRate: 16_000,
      outputAudioSampleRate: 24_000
    )
  )

  let data = try JSONEncoder().encode(capability)
  let decoded = try JSONDecoder().decode(ModelCapability.self, from: data)

  #expect(decoded == capability)
  #expect(decoded.supports(.visionLive))
  #expect(!decoded.supports(.ttsStudio))
}

@Test
func modelBundleFindsComponentsByRole() {
  let bundle = ModelBundle(
    id: "minicpm-o-4.5-q4km",
    displayName: "MiniCPM-o 4.5",
    version: "4.5",
    variant: "Q4_K_M",
    capability: ModelCapability(
      adapter: .miniCPMO,
      interactionModes: [.visionLive],
      inputs: [.audio, .camera],
      outputs: [.text, .audio]
    ),
    components: [
      ModelComponent(
        role: .llm,
        relativePath: "MiniCPM-o-4_5-Q4_K_M.gguf"
      ),
      ModelComponent(
        role: .vision,
        relativePath: "vision/MiniCPM-o-4_5-vision-F16.gguf"
      ),
    ]
  )

  #expect(bundle.component(.llm)?.relativePath.hasSuffix(".gguf") == true)
  #expect(bundle.component(.audio) == nil)
}

@Test
func liveInputFramePreservesBinaryPayloads() {
  let audio = Data([0, 1, 2, 3])
  let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
  let frame = LiveInputFrame(
    audioPCM: audio,
    jpegFrames: [image],
    maxSliceCount: 2,
    forceListen: true
  )

  #expect(frame.audioPCM == audio)
  #expect(frame.jpegFrames == [image])
  #expect(frame.maxSliceCount == 2)
  #expect(frame.forceListen)
}
