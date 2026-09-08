import ComniDomain
import Foundation
import Testing

@testable import ComniRuntime

@Test
func sessionInitMatchesBackendContract() throws {
  let reference = Data([0, 1, 2, 3])
  let configuration = LiveSessionConfiguration(
    modelID: "minicpm-o-4.5-q4km",
    mode: .visionLive,
    systemPrompt: "Streaming Omni Conversation.",
    referenceAudio: reference,
    generateAudio: true,
    sampling: [
      "chunk_ms": .integer(1000),
      "temperature": .number(0.7),
    ]
  )

  let text = try BackendProtocolCodec().encodeSessionInit(configuration)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
  )
  let payload = try #require(object["payload"] as? [String: Any])
  let voice = try #require(payload["voice"] as? [String: Any])
  let config = try #require(payload["config"] as? [String: Any])

  #expect(object["type"] as? String == "session.init")
  #expect(payload["mode"] as? String == "full_duplex")
  #expect(payload["use_tts"] as? Bool == true)
  #expect(payload["system_prompt"] as? String == "Streaming Omni Conversation.")
  #expect(voice["ref_audio"] as? String == reference.base64EncodedString())
  #expect(config["generate_audio"] as? Bool == true)
  #expect(config["chunk_ms"] as? Int == 1000)
}

@Test
func inputFrameMatchesBackendContract() throws {
  let audio = Data([0, 1, 2, 3])
  let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
  let frame = LiveInputFrame(
    audioPCM: audio,
    jpegFrames: [jpeg],
    maxSliceCount: 2,
    forceListen: true
  )

  let text = try BackendProtocolCodec().encodeInput(frame)
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
  )
  let input = try #require(object["input"] as? [String: Any])
  let frames = try #require(input["video_frames"] as? [String])

  #expect(object["type"] as? String == "input.append")
  #expect(input["audio"] as? String == audio.base64EncodedString())
  #expect(frames == [jpeg.base64EncodedString()])
  #expect(input["max_slice_nums"] as? Int == 2)
  #expect(input["force_listen"] as? Bool == true)
}

@Test
func decodesBackendDeltaEvents() throws {
  let audio = Data([4, 5, 6])
  let payload = """
    {
      "type": "response.output.delta",
      "kind": "audio",
      "session_id": "session-1",
      "audio": "\(audio.base64EncodedString())",
      "metrics": {
        "backend": "llama.cpp-omni",
        "kv_cache_length": 42
      }
    }
    """

  let events = try BackendProtocolCodec().decodeEvent(payload)

  #expect(events.contains(.stateChanged(.speaking)))
  #expect(events.contains(.audioDelta(audio)))
  #expect(
    events.contains(
      .metrics(
        RuntimeMetrics(
          backend: "llama.cpp-omni",
          kvCacheLength: 42
        )
      )
    )
  )
}

@Test
func chatInitAndRequestMatchBackendContract() throws {
  let codec = BackendProtocolCodec()
  let initText = try codec.encodeSessionInit(
    LiveSessionConfiguration(
      modelID: "model",
      mode: .chat,
      generateAudio: true
    )
  )
  let initObject = try #require(
    JSONSerialization.jsonObject(with: Data(initText.utf8)) as? [String: Any]
  )
  let initPayload = try #require(initObject["payload"] as? [String: Any])
  #expect(initPayload["mode"] as? String == "turn_based")

  let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
  let requestText = try codec.encodeChatRequest(
    ChatRequest(
      messages: [
        ChatMessage(
          role: .user,
          content: [.text("Describe this image."), .imageJPEG(image)]
        )
      ],
      ttsEnabled: true,
      enableThinking: true
    )
  )
  let requestObject = try #require(
    JSONSerialization.jsonObject(with: Data(requestText.utf8)) as? [String: Any]
  )
  let input = try #require(requestObject["input"] as? [String: Any])
  let messages = try #require(input["messages"] as? [[String: Any]])
  let content = try #require(messages.first?["content"] as? [[String: Any]])

  #expect(requestObject["type"] as? String == "input.append")
  #expect(input["streaming"] as? Bool == true)
  #expect(input["use_tts_template"] as? Bool == true)
  #expect(input["enable_thinking"] as? Bool == true)
  #expect(content[0]["type"] as? String == "text")
  #expect(content[1]["type"] as? String == "image")
  #expect(content[1]["data"] as? String == image.base64EncodedString())
}

@Test
func responseDoneProducesCompletionWithoutRepeatingTextDelta() throws {
  let payload = """
    {
      "type": "response.done",
      "text": "complete answer",
      "audio": null,
      "reason": "turn_end"
    }
    """

  let events = try BackendProtocolCodec().decodeEvent(payload)

  #expect(
    events == [
      .responseCompleted(
        text: "complete answer",
        audio: nil,
        reason: "turn_end"
      )
    ]
  )
}

@Test
func rejectsTTSStudioConfigurationForBackendCodec() {
  let configuration = LiveSessionConfiguration(
    modelID: "model",
    mode: .ttsStudio
  )

  #expect(throws: BackendProtocolError.unsupportedMode(.ttsStudio)) {
    try BackendProtocolCodec().encodeSessionInit(configuration)
  }
}
