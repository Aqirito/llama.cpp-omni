import ComniDomain
import Foundation
import Testing

@testable import ComniRuntime

@Test
func discoversInstalledMiniCPMVariantsWithoutModifyingModelDirectory() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  try createFile("MiniCPM-o-4_5-Q4_K_M.gguf", under: root)
  try createFile("MiniCPM-o-4_5-Q8_0.gguf", under: root)
  try createFile("audio/MiniCPM-o-4_5-audio-F16.gguf", under: root)
  try createFile("vision/MiniCPM-o-4_5-vision-F16.gguf", under: root)

  let installations = try MiniCPMOModelDiscovery().discover(in: root)

  #expect(installations.count == 2)
  #expect(installations.allSatisfy { $0.supportsVisionLive })
  #expect(installations.allSatisfy { !$0.supportsSpeechOutput })
  #expect(
    installations.allSatisfy {
      $0.missingComponents.contains(.token2wavHiFiGAN)
    }
  )
}

@Test
func exposesSpeechOutputOnlyWhenAllTTSComponentsExist() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  for path in [
    "MiniCPM-o-4_5-Q4_K_M.gguf",
    "audio/MiniCPM-o-4_5-audio-F16.gguf",
    "vision/MiniCPM-o-4_5-vision-F16.gguf",
    "tts/MiniCPM-o-4_5-tts-F16.gguf",
    "tts/MiniCPM-o-4_5-projector-F16.gguf",
    "token2wav-gguf/encoder.gguf",
    "token2wav-gguf/flow_matching.gguf",
    "token2wav-gguf/flow_extra.gguf",
    "token2wav-gguf/hifigan2.gguf",
    "token2wav-gguf/prompt_cache.gguf",
  ] {
    try createFile(path, under: root)
  }

  let installation = try #require(
    MiniCPMOModelDiscovery().discover(in: root).first
  )

  #expect(installation.supportsVisionLive)
  #expect(installation.supportsSpeechOutput)
  #expect(installation.bundle.capability.outputs.contains(.audio))
}

@Test
func treatsGitLFSPointersAsMissingModelComponents() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  try createFile("MiniCPM-o-4_5-Q4_K_M.gguf", under: root)
  try createFile(
    "audio/MiniCPM-o-4_5-audio-F16.gguf",
    under: root,
    data: Data(
      "version https://git-lfs.github.com/spec/v1\n".utf8
    )
  )
  try createFile("vision/MiniCPM-o-4_5-vision-F16.gguf", under: root)

  let installation = try #require(
    MiniCPMOModelDiscovery().discover(in: root).first
  )

  #expect(!installation.supportsVisionLive)
  #expect(installation.missingComponents.contains(.audio))
}

private func createFile(
  _ relativePath: String,
  under root: URL,
  data: Data = Data("GGUF".utf8)
) throws {
  let url = root.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url)
}
