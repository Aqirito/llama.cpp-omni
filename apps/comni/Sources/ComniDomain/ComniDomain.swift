import Foundation

public enum EngineAdapter: String, Codable, Sendable {
  case miniCPMO = "minicpm_o"
  case voxCPM = "voxcpm"
  case llama
}

public enum InteractionMode: String, Codable, CaseIterable, Sendable {
  case chat
  case voiceLive = "voice_live"
  case visionLive = "vision_live"
  case ttsStudio = "tts_studio"
}

public enum InputModality: String, Codable, Sendable {
  case text
  case image
  case audio
  case video
  case camera
  case referenceAudio = "reference_audio"
  case voiceDescription = "voice_description"
}

public enum OutputModality: String, Codable, Sendable {
  case text
  case audio
}

public enum ModelFeature: String, Codable, Sendable {
  case thinking
  case voiceClone = "voice_clone"
  case voiceDesign = "voice_design"
  case proactiveSpeech = "proactive_speech"
  case streamingAudio = "streaming_audio"
}

public struct ModelLimits: Codable, Equatable, Sendable {
  public var maxContext: Int?
  public var inputAudioSampleRate: Int?
  public var outputAudioSampleRate: Int?
  public var maxActiveSessions: Int

  public init(
    maxContext: Int? = nil,
    inputAudioSampleRate: Int? = nil,
    outputAudioSampleRate: Int? = nil,
    maxActiveSessions: Int = 1
  ) {
    self.maxContext = maxContext
    self.inputAudioSampleRate = inputAudioSampleRate
    self.outputAudioSampleRate = outputAudioSampleRate
    self.maxActiveSessions = maxActiveSessions
  }

  enum CodingKeys: String, CodingKey {
    case maxContext = "max_context"
    case inputAudioSampleRate = "input_audio_hz"
    case outputAudioSampleRate = "output_audio_hz"
    case maxActiveSessions = "max_active_sessions"
  }
}

public struct ModelCapability: Codable, Equatable, Sendable {
  public var adapter: EngineAdapter
  public var interactionModes: Set<InteractionMode>
  public var inputs: Set<InputModality>
  public var outputs: Set<OutputModality>
  public var features: Set<ModelFeature>
  public var limits: ModelLimits

  public init(
    adapter: EngineAdapter,
    interactionModes: Set<InteractionMode>,
    inputs: Set<InputModality>,
    outputs: Set<OutputModality>,
    features: Set<ModelFeature> = [],
    limits: ModelLimits = ModelLimits()
  ) {
    self.adapter = adapter
    self.interactionModes = interactionModes
    self.inputs = inputs
    self.outputs = outputs
    self.features = features
    self.limits = limits
  }

  public func supports(_ mode: InteractionMode) -> Bool {
    interactionModes.contains(mode)
  }

  enum CodingKeys: String, CodingKey {
    case adapter
    case interactionModes = "interaction_modes"
    case inputs
    case outputs
    case features
    case limits
  }
}

public enum ModelComponentRole: String, Codable, Sendable {
  case llm
  case audio
  case vision
  case tts
  case ttsProjector = "tts_projector"
  case token2wavEncoder = "token2wav_encoder"
  case token2wavFlowMatching = "token2wav_flow_matching"
  case token2wavFlowExtra = "token2wav_flow_extra"
  case token2wavHiFiGAN = "token2wav_hifigan"
  case token2wavPromptCache = "token2wav_prompt_cache"
  case voxCPMBaseLM = "voxcpm_base_lm"
  case voxCPMAcoustic = "voxcpm_acoustic"
}

public struct ModelComponent: Codable, Equatable, Identifiable, Sendable {
  public var id: String { role.rawValue }
  public var role: ModelComponentRole
  public var relativePath: String
  public var byteSize: Int64?
  public var sha256: String?

  public init(
    role: ModelComponentRole,
    relativePath: String,
    byteSize: Int64? = nil,
    sha256: String? = nil
  ) {
    self.role = role
    self.relativePath = relativePath
    self.byteSize = byteSize
    self.sha256 = sha256
  }

  enum CodingKeys: String, CodingKey {
    case role
    case relativePath = "path"
    case byteSize = "size"
    case sha256
  }
}

public struct ModelBundle: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var version: String
  public var variant: String?
  public var capability: ModelCapability
  public var components: [ModelComponent]

  public init(
    id: String,
    displayName: String,
    version: String,
    variant: String? = nil,
    capability: ModelCapability,
    components: [ModelComponent]
  ) {
    self.id = id
    self.displayName = displayName
    self.version = version
    self.variant = variant
    self.capability = capability
    self.components = components
  }

  public func component(_ role: ModelComponentRole) -> ModelComponent? {
    components.first { $0.role == role }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case version
    case variant
    case capability
    case components
  }
}

public enum ChatRole: String, Codable, Sendable {
  case system
  case user
  case assistant
}

public enum ChatContent: Equatable, Sendable {
  case text(String)
  case imageJPEG(Data)
  case audioPCM(Data)
  case videoMP4(Data, stackFrames: Int)
}

public struct ChatMessage: Equatable, Identifiable, Sendable {
  public var id: UUID
  public var role: ChatRole
  public var content: [ChatContent]

  public init(
    id: UUID = UUID(),
    role: ChatRole,
    content: [ChatContent]
  ) {
    self.id = id
    self.role = role
    self.content = content
  }

  public init(
    id: UUID = UUID(),
    role: ChatRole,
    text: String
  ) {
    self.init(id: id, role: role, content: [.text(text)])
  }

  public var text: String {
    content.compactMap {
      if case .text(let text) = $0 { text } else { nil }
    }.joined()
  }
}

public struct ChatRequest: Equatable, Sendable {
  public var messages: [ChatMessage]
  public var streaming: Bool
  public var maxNewTokens: Int
  public var lengthPenalty: Double
  public var ttsEnabled: Bool
  public var ttsReferenceAudio: Data?
  public var omniMode: Bool
  public var enableThinking: Bool

  public init(
    messages: [ChatMessage],
    streaming: Bool = true,
    maxNewTokens: Int = 512,
    lengthPenalty: Double = 1.1,
    ttsEnabled: Bool = false,
    ttsReferenceAudio: Data? = nil,
    omniMode: Bool = false,
    enableThinking: Bool = false
  ) {
    self.messages = messages
    self.streaming = streaming
    self.maxNewTokens = maxNewTokens
    self.lengthPenalty = lengthPenalty
    self.ttsEnabled = ttsEnabled
    self.ttsReferenceAudio = ttsReferenceAudio
    self.omniMode = omniMode
    self.enableThinking = enableThinking
  }
}

public struct LiveSessionConfiguration: Equatable, Sendable {
  public var modelID: String
  public var mode: InteractionMode
  public var systemPrompt: String
  public var referenceAudio: Data?
  public var ttsReferenceAudio: Data?
  public var generateAudio: Bool
  public var sampling: [String: JSONValue]

  public init(
    modelID: String,
    mode: InteractionMode,
    systemPrompt: String = "Streaming Omni Conversation.",
    referenceAudio: Data? = nil,
    ttsReferenceAudio: Data? = nil,
    generateAudio: Bool = true,
    sampling: [String: JSONValue] = [:]
  ) {
    self.modelID = modelID
    self.mode = mode
    self.systemPrompt = systemPrompt
    self.referenceAudio = referenceAudio
    self.ttsReferenceAudio = ttsReferenceAudio
    self.generateAudio = generateAudio
    self.sampling = sampling
  }
}

public struct LiveInputFrame: Equatable, Sendable {
  public var audioPCM: Data
  public var jpegFrames: [Data]
  public var maxSliceCount: Int?
  public var forceListen: Bool

  public init(
    audioPCM: Data,
    jpegFrames: [Data] = [],
    maxSliceCount: Int? = nil,
    forceListen: Bool = false
  ) {
    self.audioPCM = audioPCM
    self.jpegFrames = jpegFrames
    self.maxSliceCount = maxSliceCount
    self.forceListen = forceListen
  }
}

public enum LiveSessionState: String, Codable, Sendable {
  case idle
  case preparing
  case ready
  case listening
  case speaking
  case paused
  case ending
  case ended
  case failed
}

public struct RuntimeMetrics: Codable, Equatable, Sendable {
  public var backend: String?
  public var kvCacheLength: Int?
  public var prefillMilliseconds: Double?
  public var generateMilliseconds: Double?
  public var wallClockMilliseconds: Double?

  public init(
    backend: String? = nil,
    kvCacheLength: Int? = nil,
    prefillMilliseconds: Double? = nil,
    generateMilliseconds: Double? = nil,
    wallClockMilliseconds: Double? = nil
  ) {
    self.backend = backend
    self.kvCacheLength = kvCacheLength
    self.prefillMilliseconds = prefillMilliseconds
    self.generateMilliseconds = generateMilliseconds
    self.wallClockMilliseconds = wallClockMilliseconds
  }

  enum CodingKeys: String, CodingKey {
    case backend
    case kvCacheLength = "kv_cache_length"
    case prefillMilliseconds = "prefill_ms"
    case generateMilliseconds = "generate_ms"
    case wallClockMilliseconds = "wall_clock_ms"
  }
}

public enum LiveSessionEvent: Equatable, Sendable {
  case stateChanged(LiveSessionState)
  case sessionCreated(id: String)
  case textDelta(String)
  case audioDelta(Data)
  case responseCompleted(text: String, audio: Data?, reason: String)
  case metrics(RuntimeMetrics)
  case ended(reason: String)
}

public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case integer(Int)
  case number(Double)
  case boolean(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .boolean(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
}
