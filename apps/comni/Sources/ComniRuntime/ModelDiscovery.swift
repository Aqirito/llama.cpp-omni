import ComniDomain
import Foundation

public struct ModelInstallation: Identifiable, Sendable {
  public var id: String { bundle.id }
  public var bundle: ModelBundle
  public var rootURL: URL
  public var missingComponents: Set<ModelComponentRole>

  public var supportsVisionLive: Bool {
    missingComponents.isDisjoint(with: [.llm, .audio, .vision])
  }

  public var supportsSpeechOutput: Bool {
    missingComponents.isDisjoint(
      with: [
        .tts,
        .ttsProjector,
        .token2wavEncoder,
        .token2wavFlowMatching,
        .token2wavFlowExtra,
        .token2wavHiFiGAN,
        .token2wavPromptCache,
      ]
    )
  }

  public func url(for role: ModelComponentRole) -> URL? {
    guard let component = bundle.component(role) else {
      return nil
    }
    return rootURL.appendingPathComponent(component.relativePath)
  }
}

public struct MiniCPMOModelDiscovery: Sendable {
  public init() {}

  public func discover(in rootURL: URL) throws -> [ModelInstallation] {
    let fileManager = FileManager.default
    let directChildren = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    let llmFiles =
      directChildren
      .filter {
        let name = $0.lastPathComponent
        return name.hasPrefix("MiniCPM-o-4_5-") && name.hasSuffix(".gguf")
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    return llmFiles.map { llmURL in
      installation(rootURL: rootURL, llmURL: llmURL)
    }
  }

  private func installation(rootURL: URL, llmURL: URL) -> ModelInstallation {
    let fileManager = FileManager.default
    let variant =
      llmURL
      .deletingPathExtension()
      .lastPathComponent
      .replacingOccurrences(of: "MiniCPM-o-4_5-", with: "")
    let components = componentLayout(
      llmFilename: llmURL.lastPathComponent
    )
    let missing = Set(
      components.compactMap { component in
        let url = rootURL.appendingPathComponent(component.relativePath)
        return isGGUFFile(url, fileManager: fileManager) ? nil : component.role
      }
    )

    var outputs: Set<OutputModality> = [.text]
    let speechRoles: Set<ModelComponentRole> = [
      .tts,
      .ttsProjector,
      .token2wavEncoder,
      .token2wavFlowMatching,
      .token2wavFlowExtra,
      .token2wavHiFiGAN,
      .token2wavPromptCache,
    ]
    if missing.isDisjoint(with: speechRoles) {
      outputs.insert(.audio)
    }

    let bundle = ModelBundle(
      id: "minicpm-o-4.5-\(variant.lowercased())",
      displayName: "MiniCPM-o 4.5",
      version: "4.5",
      variant: variant,
      capability: ModelCapability(
        adapter: .miniCPMO,
        interactionModes: [.chat, .voiceLive, .visionLive],
        inputs: [.text, .image, .audio, .video, .camera],
        outputs: outputs,
        features: [.thinking, .voiceClone, .proactiveSpeech],
        limits: ModelLimits(
          maxContext: 8192,
          inputAudioSampleRate: 16_000,
          outputAudioSampleRate: 24_000,
          maxActiveSessions: 1
        )
      ),
      components: components
    )
    return ModelInstallation(
      bundle: bundle,
      rootURL: rootURL,
      missingComponents: missing
    )
  }

  private func componentLayout(llmFilename: String) -> [ModelComponent] {
    [
      ModelComponent(role: .llm, relativePath: llmFilename),
      ModelComponent(
        role: .audio,
        relativePath: "audio/MiniCPM-o-4_5-audio-F16.gguf"
      ),
      ModelComponent(
        role: .vision,
        relativePath: "vision/MiniCPM-o-4_5-vision-F16.gguf"
      ),
      ModelComponent(
        role: .tts,
        relativePath: "tts/MiniCPM-o-4_5-tts-F16.gguf"
      ),
      ModelComponent(
        role: .ttsProjector,
        relativePath: "tts/MiniCPM-o-4_5-projector-F16.gguf"
      ),
      ModelComponent(
        role: .token2wavEncoder,
        relativePath: "token2wav-gguf/encoder.gguf"
      ),
      ModelComponent(
        role: .token2wavFlowMatching,
        relativePath: "token2wav-gguf/flow_matching.gguf"
      ),
      ModelComponent(
        role: .token2wavFlowExtra,
        relativePath: "token2wav-gguf/flow_extra.gguf"
      ),
      ModelComponent(
        role: .token2wavHiFiGAN,
        relativePath: "token2wav-gguf/hifigan2.gguf"
      ),
      ModelComponent(
        role: .token2wavPromptCache,
        relativePath: "token2wav-gguf/prompt_cache.gguf"
      ),
    ]
  }

  private func isGGUFFile(_ url: URL, fileManager: FileManager) -> Bool {
    guard fileManager.isReadableFile(atPath: url.path) else {
      return false
    }
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      return try handle.read(upToCount: 4) == Data("GGUF".utf8)
    } catch {
      return false
    }
  }
}
