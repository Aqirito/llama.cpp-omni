import ComniDomain
import ComniRuntime
import CoreImage
import Darwin
import Foundation

@main
struct ComniProbe {
  static func main() async {
    do {
      if CommandLine.arguments.contains("--web-stack")
        || CommandLine.arguments.contains("--web-e2e")
      {
        try await runWebStackProbe(
          runE2E: CommandLine.arguments.contains("--web-e2e")
        )
        return
      }
      let baseURL = try parseBaseURL()
      let client = OmniBackendClient(baseURL: baseURL)
      let chatPrompt = argumentValue(after: "--chat")
      let configuration = LiveSessionConfiguration(
        modelID: "probe",
        mode: chatPrompt == nil ? .visionLive : .chat,
        generateAudio: CommandLine.arguments.contains("--tts")
      )
      let events = try await client.connect(configuration: configuration)
      let shouldSendFrame = CommandLine.arguments.contains("--frame")

      for try await event in events {
        print(describe(event))
        if case .sessionCreated = event {
          if let chatPrompt {
            var messages: [ChatMessage] = []
            if let previousUser = argumentValue(after: "--history-user"),
              let previousAssistant = argumentValue(after: "--history-assistant")
            {
              messages.append(ChatMessage(role: .user, text: previousUser))
              messages.append(
                ChatMessage(role: .assistant, text: previousAssistant)
              )
            }
            messages.append(ChatMessage(role: .user, text: chatPrompt))
            try await client.appendChat(
              ChatRequest(
                messages: messages,
                ttsEnabled: CommandLine.arguments.contains("--tts")
              )
            )
            print("input.append chat=\(chatPrompt.utf8.count)")
          } else if shouldSendFrame {
            try await client.append(makeTestFrame())
            print("input.append audio=64000 jpeg=1")
            Task {
              try? await Task.sleep(for: .seconds(10))
              try? await client.close(reason: "probe_complete")
            }
          } else {
            try await client.close(reason: "probe_complete")
          }
        } else if case .responseCompleted = event, chatPrompt != nil {
          try await client.close(reason: "probe_complete")
        }
      }
    } catch {
      FileHandle.standardError.write(
        Data("ComniProbe failed: \(error.localizedDescription)\n".utf8)
      )
      exit(EXIT_FAILURE)
    }
  }

  private static func parseBaseURL() throws -> URL {
    let url =
      CommandLine.arguments.dropFirst()
      .compactMap(URL.init(string:))
      .first { $0.host != nil }
      ?? URL(string: "http://127.0.0.1:11435")!
    guard url.host != nil else {
      throw OmniBackendClientError.invalidEndpoint
    }
    return url
  }

  private static func describe(_ event: LiveSessionEvent) -> String {
    switch event {
    case .stateChanged(let state):
      "state=\(state.rawValue)"
    case .sessionCreated(let id):
      "session.created id=\(id)"
    case .textDelta(let text):
      "text.delta bytes=\(text.utf8.count) value=\(String(reflecting: text))"
    case .audioDelta(let data):
      "audio.delta bytes=\(data.count)"
    case .responseCompleted(let text, let audio, let reason):
      "response.done text=\(text.utf8.count) value=\(String(reflecting: text)) audio=\(audio?.count ?? 0) reason=\(reason)"
    case .metrics(let metrics):
      "metrics backend=\(metrics.backend ?? "-") kv=\(metrics.kvCacheLength ?? -1)"
    case .ended(let reason):
      "session.ended reason=\(reason)"
    }
  }

  private static func argumentValue(after option: String) -> String? {
    guard
      let index = CommandLine.arguments.firstIndex(of: option),
      CommandLine.arguments.indices.contains(index + 1)
    else {
      return nil
    }
    return CommandLine.arguments[index + 1]
  }

  private static func makeTestFrame() throws -> LiveInputFrame {
    let image = CIImage(color: CIColor(red: 0.15, green: 0.2, blue: 0.25))
      .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    guard
      let jpeg = CIContext().jpegRepresentation(
        of: image,
        colorSpace: CGColorSpaceCreateDeviceRGB()
      )
    else {
      throw CameraProbeError.jpegEncodingFailed
    }
    return LiveInputFrame(
      audioPCM: Data(count: 16_000 * MemoryLayout<Float>.size),
      jpegFrames: [jpeg],
      maxSliceCount: 1,
      forceListen: true
    )
  }

  private static func runWebStackProbe(runE2E: Bool) async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let modelPath = environment["COMNI_MODEL_DIR"],
      let serverPath = environment["COMNI_SERVER_PATH"],
      let demoPath = environment["COMNI_DEMO_DIR"],
      let pythonPath = environment["COMNI_PYTHON_PATH"]
    else {
      throw WebProbeError.missingEnvironment
    }

    let installations = try MiniCPMOModelDiscovery().discover(
      in: URL(fileURLWithPath: modelPath, isDirectory: true)
    )
    guard
      let installation =
        installations.first(where: {
          $0.bundle.variant == "Q4_K_M" && $0.supportsVisionLive
        })
        ?? installations.first(where: \.supportsVisionLive),
      let modelURL = installation.url(for: .llm)
    else {
      throw WebProbeError.modelNotFound
    }

    let ports = try LoopbackPortAllocator().allocate(count: 4)
    let configuration = WebStackConfiguration(
      serverURL: URL(fileURLWithPath: serverPath),
      pythonURL: URL(fileURLWithPath: pythonPath),
      demoRootURL: URL(fileURLWithPath: demoPath, isDirectory: true),
      modelURL: modelURL,
      backendPort: ports[0],
      workerPort: ports[1],
      gatewayPort: ports[2],
      internalGatewayPort: ports[3]
    )
    let manager = WebStackManager()
    let eventTask = Task {
      for await event in manager.events {
        print("web.event \(event)")
      }
    }
    do {
      try await manager.start(configuration)
      let (data, response) = try await URLSession.shared.data(
        from: configuration.webURL
      )
      guard
        let response = response as? HTTPURLResponse,
        response.statusCode == 200,
        !data.isEmpty
      else {
        throw WebProbeError.webPageUnavailable
      }
      try await verifyMobileAssets(configuration)
      if runE2E {
        try await runGatewayChat(configuration)
        try await runGatewayChatTTS(configuration)
        try await runGatewayOmni(configuration)
        print("WEB_E2E_OK")
      }
      print("WEB_STACK_OK \(configuration.webURL.absoluteString)")
      await manager.stop()
      eventTask.cancel()
    } catch {
      await manager.stop()
      eventTask.cancel()
      throw error
    }
  }

  private static func verifyMobileAssets(
    _ configuration: WebStackConfiguration
  ) async throws {
    let (data, response) = try await URLSession.shared.data(
      from: configuration.webURL
    )
    guard
      let response = response as? HTTPURLResponse,
      response.statusCode == 200,
      let html = String(data: data, encoding: .utf8),
      html.contains(#"<div id="root"></div>"#)
    else {
      throw WebProbeError.webPageUnavailable
    }

    let expression = try NSRegularExpression(
      pattern: #"(?:src|href)="\./([^"]+)""#
    )
    let range = NSRange(html.startIndex..., in: html)
    let assets = expression.matches(in: html, range: range).compactMap {
      match -> String? in
      guard
        let range = Range(match.range(at: 1), in: html)
      else {
        return nil
      }
      return String(html[range])
    }
    guard !assets.isEmpty else {
      throw WebProbeError.mobileAssetsMissing
    }
    for asset in assets {
      let url = configuration.webURL.appendingPathComponent(asset)
      let (_, response) = try await URLSession.shared.data(from: url)
      guard
        let response = response as? HTTPURLResponse,
        response.statusCode == 200
      else {
        throw WebProbeError.mobileAssetUnavailable(asset)
      }
    }

    let statusURL = URL(
      string: "http://127.0.0.1:\(configuration.gatewayPort)/status"
    )!
    let (statusData, statusResponse) = try await URLSession.shared.data(
      from: statusURL
    )
    guard
      let statusResponse = statusResponse as? HTTPURLResponse,
      statusResponse.statusCode == 200,
      let status = try JSONSerialization.jsonObject(with: statusData)
        as? [String: Any],
      status["gateway_healthy"] as? Bool == true,
      (status["idle_workers"] as? Int ?? 0) >= 1
    else {
      throw WebProbeError.gatewayNotReady
    }
    print("MOBILE_ASSETS_OK count=\(assets.count)")
  }

  private static func runGatewayChat(
    _ configuration: WebStackConfiguration
  ) async throws {
    let socket = try gatewaySocket(configuration, mode: "chat")
    defer { socket.cancel(with: .normalClosure, reason: nil) }
    try await gatewayHandshake(socket, payload: [:])
    try await sendJSON(
      [
        "type": "input.append",
        "input": [
          "messages": [
            ["role": "user", "content": "请只回答：测试"]
          ],
          "streaming": true,
          "generation": [
            "max_new_tokens": 32,
            "length_penalty": 1.1,
          ],
          "image": ["max_slice_nums": 1],
          "omni_mode": false,
          "tts": ["enabled": false],
          "use_tts_template": false,
          "enable_thinking": false,
        ],
      ],
      to: socket
    )

    var streamedText = ""
    var completedText = ""
    while true {
      let message = try await receiveJSON(from: socket)
      switch message["type"] as? String {
      case "response.output.delta":
        if message["kind"] as? String == "text" {
          streamedText += message["text"] as? String ?? ""
        }
      case "response.done":
        completedText = message["text"] as? String ?? streamedText
        try await sendJSON(
          ["type": "session.close", "reason": "chat_e2e_complete"],
          to: socket
        )
      case "session.closed":
        guard completedText.contains("测试") else {
          throw WebProbeError.chatResponseInvalid(completedText)
        }
        print("GATEWAY_CHAT_OK \(String(reflecting: completedText))")
        return
      case "error":
        throw WebProbeError.gatewayError(String(describing: message["error"]))
      default:
        break
      }
    }
  }

  private static func runGatewayOmni(
    _ configuration: WebStackConfiguration
  ) async throws {
    let socket = try gatewaySocket(configuration, mode: "video")
    defer { socket.cancel(with: .normalClosure, reason: nil) }
    try await gatewayHandshake(
      socket,
      payload: [
        "mode": "full_duplex",
        "use_tts": false,
        "system_prompt": "Streaming Omni Conversation.",
      ]
    )

    let frame = try makeTestFrame()
    try await sendJSON(
      [
        "type": "input.append",
        "input": [
          "audio": frame.audioPCM.base64EncodedString(),
          "video_frames": frame.jpegFrames.map {
            $0.base64EncodedString()
          },
          "max_slice_nums": frame.maxSliceCount ?? 1,
          "force_listen": true,
        ],
      ],
      to: socket
    )

    var listenSeen = false
    while true {
      let message = try await receiveJSON(from: socket)
      switch message["type"] as? String {
      case "response.output.delta":
        if message["kind"] as? String == "listen" {
          listenSeen = true
          try await sendJSON(
            ["type": "session.close", "reason": "omni_e2e_complete"],
            to: socket
          )
        }
      case "session.closed":
        guard listenSeen else {
          throw WebProbeError.omniListenMissing
        }
        print("GATEWAY_OMNI_OK listen=true")
        return
      case "error":
        throw WebProbeError.gatewayError(String(describing: message["error"]))
      default:
        break
      }
    }
  }

  private static func runGatewayChatTTS(
    _ configuration: WebStackConfiguration
  ) async throws {
    let referenceURL = URL(
      string:
        "http://127.0.0.1:\(configuration.gatewayPort)/api/default_ref_audio"
    )!
    let (referenceData, referenceResponse) = try await URLSession.shared.data(
      from: referenceURL
    )
    guard
      let referenceResponse = referenceResponse as? HTTPURLResponse,
      referenceResponse.statusCode == 200,
      let reference = try JSONSerialization.jsonObject(with: referenceData)
        as? [String: Any],
      let referenceBase64 = reference["base64"] as? String,
      !referenceBase64.isEmpty
    else {
      throw WebProbeError.referenceAudioUnavailable
    }

    let socket = try gatewaySocket(configuration, mode: "chat")
    defer { socket.cancel(with: .normalClosure, reason: nil) }
    try await gatewayHandshake(socket, payload: [:])
    try await sendJSON(
      [
        "type": "input.append",
        "input": [
          "messages": [
            ["role": "user", "content": "请只回答：测试"]
          ],
          "streaming": true,
          "generation": [
            "max_new_tokens": 32,
            "length_penalty": 1.1,
          ],
          "image": ["max_slice_nums": 1],
          "omni_mode": false,
          "tts": [
            "enabled": true,
            "mode": "audio_assistant",
            "ref_audio_data": referenceBase64,
          ],
          "use_tts_template": true,
          "enable_thinking": false,
        ],
      ],
      to: socket
    )

    var text = ""
    var audioBytes = 0
    while true {
      let message = try await receiveJSON(from: socket)
      switch message["type"] as? String {
      case "response.output.delta":
        if message["kind"] as? String == "text" {
          text += message["text"] as? String ?? ""
        } else if message["kind"] as? String == "audio",
          let encoded = message["audio"] as? String,
          let audio = Data(base64Encoded: encoded)
        {
          audioBytes += audio.count
        }
      case "response.done":
        if text.isEmpty {
          text = message["text"] as? String ?? ""
        }
        try await sendJSON(
          ["type": "session.close", "reason": "chat_tts_e2e_complete"],
          to: socket
        )
      case "session.closed":
        guard !text.isEmpty, audioBytes > 0 else {
          throw WebProbeError.chatTTSInvalid(
            text: text,
            audioBytes: audioBytes
          )
        }
        print(
          "GATEWAY_CHAT_TTS_OK text=\(text.utf8.count) audio=\(audioBytes)"
        )
        return
      case "error":
        throw WebProbeError.gatewayError(String(describing: message["error"]))
      default:
        break
      }
    }
  }

  private static func gatewaySocket(
    _ configuration: WebStackConfiguration,
    mode: String
  ) throws -> URLSessionWebSocketTask {
    guard
      let url = URL(
        string:
          "ws://127.0.0.1:\(configuration.gatewayPort)/v1/realtime?mode=\(mode)"
      )
    else {
      throw WebProbeError.invalidGatewayURL
    }
    let socket = URLSession.shared.webSocketTask(with: url)
    socket.resume()
    return socket
  }

  private static func gatewayHandshake(
    _ socket: URLSessionWebSocketTask,
    payload: [String: Any]
  ) async throws {
    while true {
      let message = try await receiveJSON(from: socket)
      switch message["type"] as? String {
      case "session.queue_done", "queue_done":
        try await sendJSON(
          ["type": "session.init", "payload": payload],
          to: socket
        )
      case "session.created":
        return
      case "error":
        throw WebProbeError.gatewayError(String(describing: message["error"]))
      default:
        break
      }
    }
  }

  private static func sendJSON(
    _ object: [String: Any],
    to socket: URLSessionWebSocketTask
  ) async throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard let text = String(data: data, encoding: .utf8) else {
      throw WebProbeError.invalidJSON
    }
    try await socket.send(.string(text))
  }

  private static func receiveJSON(
    from socket: URLSessionWebSocketTask,
    timeout: Duration = .seconds(120)
  ) async throws -> [String: Any] {
    let message = try await withThrowingTaskGroup(
      of: URLSessionWebSocketTask.Message.self
    ) { group in
      group.addTask {
        try await socket.receive()
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WebProbeError.websocketTimedOut
      }
      guard let first = try await group.next() else {
        throw WebProbeError.websocketClosed
      }
      group.cancelAll()
      return first
    }

    let data: Data
    switch message {
    case .string(let text):
      data = Data(text.utf8)
    case .data(let value):
      data = value
    @unknown default:
      throw WebProbeError.websocketClosed
    }
    guard
      let object = try JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else {
      throw WebProbeError.invalidJSON
    }
    return object
  }
}

private enum CameraProbeError: Error {
  case jpegEncodingFailed
}

private enum WebProbeError: Error, LocalizedError {
  case missingEnvironment
  case modelNotFound
  case webPageUnavailable
  case mobileAssetsMissing
  case mobileAssetUnavailable(String)
  case gatewayNotReady
  case chatResponseInvalid(String)
  case omniListenMissing
  case gatewayError(String)
  case invalidGatewayURL
  case invalidJSON
  case websocketTimedOut
  case websocketClosed
  case referenceAudioUnavailable
  case chatTTSInvalid(text: String, audioBytes: Int)

  var errorDescription: String? {
    switch self {
    case .missingEnvironment:
      "The Web probe environment is incomplete."
    case .modelNotFound:
      "No runnable model was found."
    case .webPageUnavailable:
      "The mobile Web page is unavailable."
    case .mobileAssetsMissing:
      "The mobile Web page does not reference built assets."
    case .mobileAssetUnavailable(let asset):
      "The mobile asset is unavailable: \(asset)"
    case .gatewayNotReady:
      "The Gateway does not have an idle Worker."
    case .chatResponseInvalid(let text):
      "The Chat response is invalid: \(String(reflecting: text))"
    case .omniListenMissing:
      "The Omni test did not receive a listen event."
    case .gatewayError(let message):
      "Gateway error: \(message)"
    case .invalidGatewayURL:
      "The Gateway WebSocket URL is invalid."
    case .invalidJSON:
      "A Gateway message is not valid JSON."
    case .websocketTimedOut:
      "The Gateway WebSocket timed out."
    case .websocketClosed:
      "The Gateway WebSocket closed unexpectedly."
    case .referenceAudioUnavailable:
      "The Gateway default reference audio is unavailable."
    case .chatTTSInvalid(let text, let audioBytes):
      "The Chat TTS response is invalid: text=\(String(reflecting: text)), audio=\(audioBytes)."
    }
  }
}
