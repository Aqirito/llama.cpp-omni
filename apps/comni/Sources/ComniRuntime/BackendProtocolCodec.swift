import ComniDomain
import Foundation

public enum BackendProtocolError: Error, Equatable, LocalizedError {
  case unsupportedMode(InteractionMode)
  case invalidMessage
  case missingField(String)
  case unsupportedEvent(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedMode(let mode):
      "Unsupported backend mode: \(mode.rawValue)"
    case .invalidMessage:
      "The backend returned an invalid message."
    case .missingField(let field):
      "The backend message is missing '\(field)'."
    case .unsupportedEvent(let type):
      "Unsupported backend event: \(type)"
    }
  }
}

public struct BackendProtocolCodec: Sendable {
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init() {
    encoder = JSONEncoder()
    decoder = JSONDecoder()
  }

  public func encodeSessionInit(
    _ configuration: LiveSessionConfiguration
  ) throws -> String {
    let backendMode: String
    switch configuration.mode {
    case .chat:
      backendMode = "turn_based"
    case .voiceLive, .visionLive:
      backendMode = "full_duplex"
    case .ttsStudio:
      throw BackendProtocolError.unsupportedMode(configuration.mode)
    }

    var config = configuration.sampling
    config["generate_audio"] = .boolean(configuration.generateAudio)

    let voice: VoicePayload?
    if configuration.referenceAudio != nil || configuration.ttsReferenceAudio != nil {
      voice = VoicePayload(
        refAudio: configuration.referenceAudio?.base64EncodedString(),
        ttsRefAudio: configuration.ttsReferenceAudio?.base64EncodedString()
      )
    } else {
      voice = nil
    }

    let message = SessionInitMessage(
      payload: SessionInitPayload(
        mode: backendMode,
        useTTS: configuration.generateAudio,
        voice: voice,
        systemPrompt: configuration.systemPrompt,
        config: config
      )
    )
    return try encode(message)
  }

  public func encodeChatRequest(_ request: ChatRequest) throws -> String {
    let messages = request.messages.map { message in
      ChatMessagePayload(
        role: message.role.rawValue,
        content: message.content.map(ChatContentPayload.init)
      )
    }
    let input = ChatInputPayload(
      messages: messages,
      streaming: request.streaming,
      generation: ChatGenerationPayload(
        maxNewTokens: request.maxNewTokens,
        lengthPenalty: request.lengthPenalty
      ),
      tts: ChatTTSPayload(
        enabled: request.ttsEnabled,
        referenceAudio: request.ttsReferenceAudio?.base64EncodedString()
      ),
      omniMode: request.omniMode,
      useTTSTemplate: request.ttsEnabled,
      enableThinking: request.enableThinking
    )
    return try encode(ChatInputAppendMessage(input: input))
  }

  public func encodeInput(_ frame: LiveInputFrame) throws -> String {
    let input = InputPayload(
      audio: frame.audioPCM.base64EncodedString(),
      videoFrames: frame.jpegFrames.map { $0.base64EncodedString() },
      maxSliceCount: frame.maxSliceCount,
      forceListen: frame.forceListen
    )
    return try encode(InputAppendMessage(input: input))
  }

  public func decodeEvent(_ text: String) throws -> [LiveSessionEvent] {
    guard let data = text.data(using: .utf8) else {
      throw BackendProtocolError.invalidMessage
    }

    let envelope = try decoder.decode(EventEnvelope.self, from: data)
    var events: [LiveSessionEvent] = []

    switch envelope.type {
    case "session.created":
      guard let sessionID = envelope.sessionID else {
        throw BackendProtocolError.missingField("session_id")
      }
      events.append(.sessionCreated(id: sessionID))
      events.append(.stateChanged(.ready))

    case "response.output.delta":
      guard let kind = envelope.kind else {
        throw BackendProtocolError.missingField("kind")
      }
      switch kind {
      case "listen":
        events.append(.stateChanged(.listening))
      case "text":
        guard let text = envelope.text else {
          throw BackendProtocolError.missingField("text")
        }
        events.append(.textDelta(text))
      case "audio":
        guard
          let encodedAudio = envelope.audio,
          let audio = Data(base64Encoded: encodedAudio)
        else {
          throw BackendProtocolError.missingField("audio")
        }
        events.append(.stateChanged(.speaking))
        events.append(.audioDelta(audio))
      default:
        throw BackendProtocolError.unsupportedEvent(
          "response.output.delta:\(kind)"
        )
      }

    case "response.done":
      let audio = envelope.audio.flatMap { Data(base64Encoded: $0) }
      events.append(
        .responseCompleted(
          text: envelope.text ?? "",
          audio: audio,
          reason: envelope.reason ?? "turn_end"
        )
      )

    case "session.closed":
      events.append(.stateChanged(.ended))
      events.append(.ended(reason: envelope.reason ?? "backend_closed"))

    default:
      throw BackendProtocolError.unsupportedEvent(envelope.type)
    }

    if let metrics = envelope.metrics {
      events.append(.metrics(metrics))
    }
    return events
  }

  private func encode<T: Encodable>(_ value: T) throws -> String {
    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
      throw BackendProtocolError.invalidMessage
    }
    return text
  }
}

private struct SessionInitMessage: Encodable {
  let type = "session.init"
  var payload: SessionInitPayload
}

private struct SessionInitPayload: Encodable {
  var mode: String
  var useTTS: Bool
  var voice: VoicePayload?
  var systemPrompt: String
  var config: [String: JSONValue]

  enum CodingKeys: String, CodingKey {
    case mode
    case useTTS = "use_tts"
    case voice
    case systemPrompt = "system_prompt"
    case config
  }
}

private struct VoicePayload: Encodable {
  var refAudio: String?
  var ttsRefAudio: String?

  enum CodingKeys: String, CodingKey {
    case refAudio = "ref_audio"
    case ttsRefAudio = "tts_ref_audio"
  }
}

private struct InputAppendMessage: Encodable {
  let type = "input.append"
  var input: InputPayload
}

private struct InputPayload: Encodable {
  var audio: String
  var videoFrames: [String]
  var maxSliceCount: Int?
  var forceListen: Bool

  enum CodingKeys: String, CodingKey {
    case audio
    case videoFrames = "video_frames"
    case maxSliceCount = "max_slice_nums"
    case forceListen = "force_listen"
  }
}

private struct ChatInputAppendMessage: Encodable {
  let type = "input.append"
  var input: ChatInputPayload
}

private struct ChatInputPayload: Encodable {
  var messages: [ChatMessagePayload]
  var streaming: Bool
  var generation: ChatGenerationPayload
  var tts: ChatTTSPayload
  var omniMode: Bool
  var useTTSTemplate: Bool
  var enableThinking: Bool

  enum CodingKeys: String, CodingKey {
    case messages
    case streaming
    case generation
    case tts
    case omniMode = "omni_mode"
    case useTTSTemplate = "use_tts_template"
    case enableThinking = "enable_thinking"
  }
}

private struct ChatMessagePayload: Encodable {
  var role: String
  var content: [ChatContentPayload]
}

private struct ChatContentPayload: Encodable {
  var type: String
  var text: String?
  var data: String?
  var stackFrames: Int?

  init(_ content: ChatContent) {
    switch content {
    case .text(let text):
      type = "text"
      self.text = text
    case .imageJPEG(let data):
      type = "image"
      self.data = data.base64EncodedString()
    case .audioPCM(let data):
      type = "audio"
      self.data = data.base64EncodedString()
    case .videoMP4(let data, let stackFrames):
      type = "video"
      self.data = data.base64EncodedString()
      self.stackFrames = stackFrames
    }
  }

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case data
    case stackFrames = "stack_frames"
  }
}

private struct ChatGenerationPayload: Encodable {
  var maxNewTokens: Int
  var lengthPenalty: Double

  enum CodingKeys: String, CodingKey {
    case maxNewTokens = "max_new_tokens"
    case lengthPenalty = "length_penalty"
  }
}

private struct ChatTTSPayload: Encodable {
  var enabled: Bool
  var referenceAudio: String?

  enum CodingKeys: String, CodingKey {
    case enabled
    case referenceAudio = "ref_audio_data"
  }
}

private struct EventEnvelope: Decodable {
  var type: String
  var sessionID: String?
  var kind: String?
  var text: String?
  var audio: String?
  var reason: String?
  var metrics: RuntimeMetrics?

  enum CodingKeys: String, CodingKey {
    case type
    case sessionID = "session_id"
    case kind
    case text
    case audio
    case reason
    case metrics
  }
}
